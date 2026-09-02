[CmdletBinding()]
param(
    [ValidateSet('gui', 'status', 'lte', 'auto', 'apply', 'diag')]
    [string]$Mode = 'gui',

    [uint32]$RatMask = 0,

    [switch]$ForceRadioCycle,

    [string]$ResultPath,

    [string]$ProgressPath
)

$ErrorActionPreference = 'Stop'
$script:ToolVersion = '1.1.1'
$script:ProgressPath = $ProgressPath
$script:ScriptPath = $PSCommandPath

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    param([string]$RequestedMode)

    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $quotedScript = '"' + $PSCommandPath.Replace('"', '\"') + '"'
    $windowStyle = if ($RequestedMode -eq 'gui') { '-WindowStyle Hidden ' } else { '' }
    $arguments = '-NoProfile {0}-ExecutionPolicy Bypass -File {1} -Mode {2}' -f $windowStyle, $quotedScript, $RequestedMode
    Start-Process -FilePath $powerShell -Verb RunAs -ArgumentList $arguments | Out-Null
}

if ($Mode -ne 'status' -and $Mode -ne 'diag' -and -not (Test-IsAdministrator)) {
    if ($Mode -eq 'apply') {
        throw 'The background RAT worker must be started from the elevated GUI.'
    }
    Restart-Elevated -RequestedMode $Mode
    exit 0
}

function Initialize-MbnNative {
    if ('MbnNative' -as [type]) {
        return
    }

    $source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

public sealed class MbnRatInfo
{
    public string InterfaceId;
    public string ProviderName;
    public uint SupportedDataClasses;
    public int SupportedDataClassesHResult;
    public int RegisterState;
    public int RegisterStateHResult;
    public int RegisterMode;
    public int RegisterModeHResult;
    public uint AvailableDataClasses;
    public int AvailableDataClassesHResult;
    public uint CurrentDataClass;
    public int CurrentDataClassHResult;
    public uint RegistrationNetworkError;
    public int RegistrationNetworkErrorHResult;
    public int HardwareRadioState;
    public int HardwareRadioStateHResult;
    public int SoftwareRadioState;
    public int SoftwareRadioStateHResult;
}

public sealed class MbnSetResult
{
    public string InterfaceId;
    public uint RequestId;
}

public static class MbnNative
{
    private const uint CLSCTX_ALL = 23;
    private const uint COINIT_APARTMENTTHREADED = 2;
    // CLSID_MbnInterfaceManager from the Windows Mobile Broadband type library.
    // The registered display name is localized/space-separated on some Windows 11 builds,
    // so it must not be discovered by comparing the CLSID key's friendly name.
    private static readonly Guid MbnInterfaceManagerClassId =
        new Guid("BDFEE05B-4418-11DD-90ED-001C257CCFF1");
    private static readonly object GuidCacheLock = new object();
    private static readonly Dictionary<string, Guid> GuidCache =
        new Dictionary<string, Guid>(StringComparer.OrdinalIgnoreCase);

    [DllImport("ole32.dll")]
    private static extern int CoInitializeEx(IntPtr reserved, uint coInit);

    [DllImport("ole32.dll")]
    private static extern void CoUninitialize();

    [DllImport("ole32.dll")]
    private static extern int CoCreateInstance(
        ref Guid classId,
        IntPtr outer,
        uint classContext,
        ref Guid interfaceId,
        out IntPtr instance);

    [DllImport("oleaut32.dll")]
    private static extern int SafeArrayGetLBound(IntPtr safeArray, uint dimension, out int lowerBound);

    [DllImport("oleaut32.dll")]
    private static extern int SafeArrayGetUBound(IntPtr safeArray, uint dimension, out int upperBound);

    [DllImport("oleaut32.dll")]
    private static extern int SafeArrayGetElement(IntPtr safeArray, ref int index, out IntPtr value);

    [DllImport("oleaut32.dll")]
    private static extern int SafeArrayDestroy(IntPtr safeArray);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetInterfacesDelegate(IntPtr self, out IntPtr safeArray);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetBstrDelegate(IntPtr self, out IntPtr value);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetIntDelegate(IntPtr self, out int value);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetUIntDelegate(IntPtr self, out uint value);

    [StructLayout(LayoutKind.Sequential)]
    private struct MbnInterfaceCapsNative
    {
        public int CellularClass;
        public int VoiceClass;
        public uint DataClass;
        public IntPtr CustomDataClass;
        public uint GsmBandClass;
        public uint CdmaBandClass;
        public IntPtr CustomBandClass;
        public uint SmsCaps;
        public uint ControlCaps;
        public IntPtr DeviceId;
        public IntPtr Manufacturer;
        public IntPtr Model;
        public IntPtr FirmwareInfo;
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetInterfaceCapabilityDelegate(
        IntPtr self,
        out MbnInterfaceCapsNative capability);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int SetRegisterModeDelegate(
        IntPtr self,
        int registerMode,
        IntPtr providerId,
        uint dataClass,
        out uint requestId);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int SetSoftwareRadioStateDelegate(
        IntPtr self,
        int radioState,
        out uint requestId);

    private static IntPtr FunctionAt(IntPtr comInterface, int slot)
    {
        IntPtr vtable = Marshal.ReadIntPtr(comInterface);
        return Marshal.ReadIntPtr(vtable, slot * IntPtr.Size);
    }

    private static T DelegateAt<T>(IntPtr comInterface, int slot) where T : class
    {
        return (T)(object)Marshal.GetDelegateForFunctionPointer(FunctionAt(comInterface, slot), typeof(T));
    }

    private static void ThrowIfFailed(int hr, string operation)
    {
        if (hr < 0)
        {
            Exception inner = Marshal.GetExceptionForHR(hr);
            string detail = inner == null ? "Unknown COM error" : inner.Message;
            throw new InvalidOperationException(
                operation + " failed (HRESULT 0x" + ((uint)hr).ToString("X8") + "): " + detail,
                inner);
        }
    }

    private static bool ContainsIdentifierToken(string text, string identifier)
    {
        int searchFrom = 0;
        while (searchFrom < text.Length)
        {
            int position = text.IndexOf(identifier, searchFrom, StringComparison.OrdinalIgnoreCase);
            if (position < 0)
                return false;

            int after = position + identifier.Length;
            bool leftBoundary = position == 0 ||
                !(Char.IsLetterOrDigit(text[position - 1]) || text[position - 1] == '_');
            bool rightBoundary = after == text.Length ||
                !(Char.IsLetterOrDigit(text[after]) || text[after] == '_');
            if (leftBoundary && rightBoundary)
                return true;

            searchFrom = position + 1;
        }
        return false;
    }

    private static string NormalizeIdentifier(string text)
    {
        if (String.IsNullOrEmpty(text))
            return String.Empty;

        StringBuilder result = new StringBuilder(text.Length);
        foreach (char character in text)
        {
            if (Char.IsLetterOrDigit(character))
                result.Append(Char.ToUpperInvariant(character));
        }
        return result.ToString();
    }

    private static Guid FindRegisteredGuid(string section, string targetName)
    {
        string cacheKey = section + "\\" + targetName;
        lock (GuidCacheLock)
        {
            Guid cached;
            if (GuidCache.TryGetValue(cacheKey, out cached))
                return cached;
        }

        RegistryView[] views = new RegistryView[] { RegistryView.Registry64, RegistryView.Registry32 };

        foreach (RegistryView view in views)
        {
            using (RegistryKey root = RegistryKey.OpenBaseKey(RegistryHive.ClassesRoot, view))
            using (RegistryKey sectionKey = root.OpenSubKey(section))
            {
                if (sectionKey == null)
                    continue;

                foreach (string subkeyName in sectionKey.GetSubKeyNames())
                {
                    Guid parsed;
                    if (!Guid.TryParse(subkeyName, out parsed))
                        continue;

                    try
                    {
                        using (RegistryKey item = sectionKey.OpenSubKey(subkeyName))
                        {
                            if (item == null)
                                continue;

                            string displayName = item.GetValue(null) as string;
                            if (String.IsNullOrEmpty(displayName))
                                continue;

                            string normalized = displayName.Trim();
                            bool exactName = String.Equals(
                                normalized, targetName, StringComparison.OrdinalIgnoreCase);
                            bool tokenName = ContainsIdentifierToken(normalized, targetName);
                            bool normalizedName = String.Equals(
                                NormalizeIdentifier(normalized),
                                NormalizeIdentifier(targetName),
                                StringComparison.OrdinalIgnoreCase);

                            // Do not let IMbnInterface partially match IMbnInterfaceManager.
                            if (exactName || tokenName || normalizedName)
                            {
                                lock (GuidCacheLock)
                                {
                                    GuidCache[cacheKey] = parsed;
                                }
                                return parsed;
                            }
                        }
                    }
                    catch
                    {
                        // Continue through registry entries that cannot be opened.
                    }
                }
            }
        }

        throw new InvalidOperationException(
            "Windows Mobile Broadband COM registration was not found: " + section + " / " + targetName);
    }

    private static IntPtr CreateInterfaceManager(out bool uninitializeCom)
    {
        int initHr = CoInitializeEx(IntPtr.Zero, COINIT_APARTMENTTHREADED);
        uninitializeCom = initHr >= 0;

        Guid classId = MbnInterfaceManagerClassId;
        Guid interfaceId = FindRegisteredGuid("Interface", "IMbnInterfaceManager");
        IntPtr manager;
        int hr = CoCreateInstance(ref classId, IntPtr.Zero, CLSCTX_ALL, ref interfaceId, out manager);
        ThrowIfFailed(hr, "CoCreateInstance(MbnInterfaceManager)");
        return manager;
    }

    private static string ReadBstr(IntPtr comInterface, int slot, out int hr)
    {
        IntPtr bstr = IntPtr.Zero;
        hr = DelegateAt<GetBstrDelegate>(comInterface, slot)(comInterface, out bstr);
        if (hr < 0 || bstr == IntPtr.Zero)
            return null;

        try
        {
            return Marshal.PtrToStringBSTR(bstr);
        }
        finally
        {
            Marshal.FreeBSTR(bstr);
        }
    }

    private static void FreeCapabilityStrings(ref MbnInterfaceCapsNative capability)
    {
        IntPtr[] strings = new IntPtr[] {
            capability.CustomDataClass,
            capability.CustomBandClass,
            capability.DeviceId,
            capability.Manufacturer,
            capability.Model,
            capability.FirmwareInfo
        };

        foreach (IntPtr value in strings)
        {
            if (value != IntPtr.Zero)
                Marshal.FreeBSTR(value);
        }
    }

    private static bool SameInterface(string left, string right)
    {
        if (String.IsNullOrEmpty(left) || String.IsNullOrEmpty(right))
            return false;

        Guid leftGuid;
        Guid rightGuid;
        if (Guid.TryParse(left, out leftGuid) && Guid.TryParse(right, out rightGuid))
            return leftGuid == rightGuid;

        return String.Equals(left.Trim(), right.Trim(), StringComparison.OrdinalIgnoreCase);
    }

    private static void GetSafeArrayBounds(IntPtr safeArray, out int lower, out int upper)
    {
        int hr = SafeArrayGetLBound(safeArray, 1, out lower);
        ThrowIfFailed(hr, "SafeArrayGetLBound");
        hr = SafeArrayGetUBound(safeArray, 1, out upper);
        ThrowIfFailed(hr, "SafeArrayGetUBound");
    }

    private static IntPtr QueryInterface(IntPtr unknown, Guid interfaceId, string name)
    {
        IntPtr result;
        int hr = Marshal.QueryInterface(unknown, ref interfaceId, out result);
        ThrowIfFailed(hr, "QueryInterface(" + name + ")");
        return result;
    }

    public static MbnRatInfo[] GetInterfaces()
    {
        bool uninitializeCom = false;
        IntPtr manager = IntPtr.Zero;
        IntPtr safeArray = IntPtr.Zero;
        List<MbnRatInfo> result = new List<MbnRatInfo>();

        try
        {
            manager = CreateInterfaceManager(out uninitializeCom);
            int hr = DelegateAt<GetInterfacesDelegate>(manager, 4)(manager, out safeArray);
            ThrowIfFailed(hr, "IMbnInterfaceManager.GetInterfaces");

            int lower;
            int upper;
            GetSafeArrayBounds(safeArray, out lower, out upper);
            Guid interfaceIid = FindRegisteredGuid("Interface", "IMbnInterface");
            Guid registrationIid = FindRegisteredGuid("Interface", "IMbnRegistration");
            Guid radioIid = Guid.Empty;
            bool radioIidAvailable = true;
            try { radioIid = FindRegisteredGuid("Interface", "IMbnRadio"); }
            catch { radioIidAvailable = false; }

            for (int index = lower; index <= upper; index++)
            {
                IntPtr unknown = IntPtr.Zero;
                IntPtr mbnInterface = IntPtr.Zero;
                IntPtr registration = IntPtr.Zero;
                IntPtr radio = IntPtr.Zero;

                try
                {
                    int elementIndex = index;
                    hr = SafeArrayGetElement(safeArray, ref elementIndex, out unknown);
                    ThrowIfFailed(hr, "SafeArrayGetElement");
                    mbnInterface = QueryInterface(unknown, interfaceIid, "IMbnInterface");
                    registration = QueryInterface(unknown, registrationIid, "IMbnRegistration");

                    MbnRatInfo info = new MbnRatInfo();
                    int stringHr;
                    info.InterfaceId = ReadBstr(mbnInterface, 3, out stringHr);
                    info.ProviderName = ReadBstr(registration, 6, out stringHr);

                    MbnInterfaceCapsNative capability;
                    info.SupportedDataClassesHResult =
                        DelegateAt<GetInterfaceCapabilityDelegate>(mbnInterface, 4)(
                            mbnInterface, out capability);
                    if (info.SupportedDataClassesHResult >= 0)
                    {
                        info.SupportedDataClasses = capability.DataClass;
                        FreeCapabilityStrings(ref capability);
                    }

                    info.RegisterStateHResult = DelegateAt<GetIntDelegate>(registration, 3)(
                        registration, out info.RegisterState);
                    info.RegisterModeHResult = DelegateAt<GetIntDelegate>(registration, 4)(
                        registration, out info.RegisterMode);
                    info.AvailableDataClassesHResult = DelegateAt<GetUIntDelegate>(registration, 8)(
                        registration, out info.AvailableDataClasses);
                    info.CurrentDataClassHResult = DelegateAt<GetUIntDelegate>(registration, 9)(
                        registration, out info.CurrentDataClass);
                    info.RegistrationNetworkErrorHResult = DelegateAt<GetUIntDelegate>(registration, 10)(
                        registration, out info.RegistrationNetworkError);
                    if (radioIidAvailable)
                    {
                        try
                        {
                            radio = QueryInterface(unknown, radioIid, "IMbnRadio");
                            info.HardwareRadioStateHResult = DelegateAt<GetIntDelegate>(radio, 3)(
                                radio, out info.HardwareRadioState);
                            info.SoftwareRadioStateHResult = DelegateAt<GetIntDelegate>(radio, 4)(
                                radio, out info.SoftwareRadioState);
                        }
                        catch
                        {
                            info.HardwareRadioStateHResult = unchecked((int)0x80004002);
                            info.SoftwareRadioStateHResult = unchecked((int)0x80004002);
                        }
                    }
                    else
                    {
                        info.HardwareRadioStateHResult = unchecked((int)0x80004002);
                        info.SoftwareRadioStateHResult = unchecked((int)0x80004002);
                    }
                    result.Add(info);
                }
                finally
                {
                    if (radio != IntPtr.Zero) Marshal.Release(radio);
                    if (registration != IntPtr.Zero) Marshal.Release(registration);
                    if (mbnInterface != IntPtr.Zero) Marshal.Release(mbnInterface);
                    if (unknown != IntPtr.Zero) Marshal.Release(unknown);
                }
            }

            return result.ToArray();
        }
        finally
        {
            if (safeArray != IntPtr.Zero) SafeArrayDestroy(safeArray);
            if (manager != IntPtr.Zero) Marshal.Release(manager);
            if (uninitializeCom) CoUninitialize();
        }
    }

    public static MbnSetResult SetPreferredDataClass(string preferredInterfaceId, uint dataClass)
    {
        if (dataClass == 0)
            throw new ArgumentOutOfRangeException("dataClass");

        bool uninitializeCom = false;
        IntPtr manager = IntPtr.Zero;
        IntPtr safeArray = IntPtr.Zero;
        IntPtr soleRegistration = IntPtr.Zero;
        string soleInterfaceId = null;
        int interfaceCount = 0;

        try
        {
            manager = CreateInterfaceManager(out uninitializeCom);
            int hr = DelegateAt<GetInterfacesDelegate>(manager, 4)(manager, out safeArray);
            ThrowIfFailed(hr, "IMbnInterfaceManager.GetInterfaces");

            int lower;
            int upper;
            GetSafeArrayBounds(safeArray, out lower, out upper);
            Guid interfaceIid = FindRegisteredGuid("Interface", "IMbnInterface");
            Guid registrationIid = FindRegisteredGuid("Interface", "IMbnRegistration");

            for (int index = lower; index <= upper; index++)
            {
                IntPtr unknown = IntPtr.Zero;
                IntPtr mbnInterface = IntPtr.Zero;
                IntPtr registration = IntPtr.Zero;

                try
                {
                    int elementIndex = index;
                    hr = SafeArrayGetElement(safeArray, ref elementIndex, out unknown);
                    ThrowIfFailed(hr, "SafeArrayGetElement");
                    mbnInterface = QueryInterface(unknown, interfaceIid, "IMbnInterface");
                    registration = QueryInterface(unknown, registrationIid, "IMbnRegistration");

                    int idHr;
                    string interfaceId = ReadBstr(mbnInterface, 3, out idHr);
                    ThrowIfFailed(idHr, "IMbnInterface.InterfaceID");
                    interfaceCount++;

                    if (interfaceCount == 1)
                    {
                        Marshal.AddRef(registration);
                        soleRegistration = registration;
                        soleInterfaceId = interfaceId;
                    }

                    if (String.IsNullOrEmpty(preferredInterfaceId) || SameInterface(interfaceId, preferredInterfaceId))
                    {
                        uint requestId;
                        hr = DelegateAt<SetRegisterModeDelegate>(registration, 12)(
                            registration, 1, IntPtr.Zero, dataClass, out requestId);
                        ThrowIfFailed(hr, "IMbnRegistration.SetRegisterMode");
                        return new MbnSetResult { InterfaceId = interfaceId, RequestId = requestId };
                    }
                }
                finally
                {
                    if (registration != IntPtr.Zero) Marshal.Release(registration);
                    if (mbnInterface != IntPtr.Zero) Marshal.Release(mbnInterface);
                    if (unknown != IntPtr.Zero) Marshal.Release(unknown);
                }
            }

            if (interfaceCount == 1 && soleRegistration != IntPtr.Zero)
            {
                uint requestId;
                hr = DelegateAt<SetRegisterModeDelegate>(soleRegistration, 12)(
                    soleRegistration, 1, IntPtr.Zero, dataClass, out requestId);
                ThrowIfFailed(hr, "IMbnRegistration.SetRegisterMode");
                return new MbnSetResult { InterfaceId = soleInterfaceId, RequestId = requestId };
            }

            throw new InvalidOperationException(
                "The Quectel network adapter could not be matched to a Windows Mobile Broadband interface.");
        }
        finally
        {
            if (soleRegistration != IntPtr.Zero) Marshal.Release(soleRegistration);
            if (safeArray != IntPtr.Zero) SafeArrayDestroy(safeArray);
            if (manager != IntPtr.Zero) Marshal.Release(manager);
            if (uninitializeCom) CoUninitialize();
        }
    }

    public static MbnSetResult SetSoftwareRadioState(string preferredInterfaceId, int radioState)
    {
        if (radioState != 0 && radioState != 1)
            throw new ArgumentOutOfRangeException("radioState");

        bool uninitializeCom = false;
        IntPtr manager = IntPtr.Zero;
        IntPtr safeArray = IntPtr.Zero;
        IntPtr soleRadio = IntPtr.Zero;
        string soleInterfaceId = null;
        int interfaceCount = 0;

        try
        {
            manager = CreateInterfaceManager(out uninitializeCom);
            int hr = DelegateAt<GetInterfacesDelegate>(manager, 4)(manager, out safeArray);
            ThrowIfFailed(hr, "IMbnInterfaceManager.GetInterfaces");

            int lower;
            int upper;
            GetSafeArrayBounds(safeArray, out lower, out upper);
            Guid interfaceIid = FindRegisteredGuid("Interface", "IMbnInterface");
            Guid radioIid = FindRegisteredGuid("Interface", "IMbnRadio");

            for (int index = lower; index <= upper; index++)
            {
                IntPtr unknown = IntPtr.Zero;
                IntPtr mbnInterface = IntPtr.Zero;
                IntPtr radio = IntPtr.Zero;

                try
                {
                    int elementIndex = index;
                    hr = SafeArrayGetElement(safeArray, ref elementIndex, out unknown);
                    ThrowIfFailed(hr, "SafeArrayGetElement");
                    mbnInterface = QueryInterface(unknown, interfaceIid, "IMbnInterface");
                    radio = QueryInterface(unknown, radioIid, "IMbnRadio");

                    int idHr;
                    string interfaceId = ReadBstr(mbnInterface, 3, out idHr);
                    ThrowIfFailed(idHr, "IMbnInterface.InterfaceID");
                    interfaceCount++;

                    if (interfaceCount == 1)
                    {
                        Marshal.AddRef(radio);
                        soleRadio = radio;
                        soleInterfaceId = interfaceId;
                    }

                    if (String.IsNullOrEmpty(preferredInterfaceId) || SameInterface(interfaceId, preferredInterfaceId))
                    {
                        uint requestId;
                        hr = DelegateAt<SetSoftwareRadioStateDelegate>(radio, 5)(
                            radio, radioState, out requestId);
                        ThrowIfFailed(hr, "IMbnRadio.SetSoftwareRadioState");
                        return new MbnSetResult { InterfaceId = interfaceId, RequestId = requestId };
                    }
                }
                finally
                {
                    if (radio != IntPtr.Zero) Marshal.Release(radio);
                    if (mbnInterface != IntPtr.Zero) Marshal.Release(mbnInterface);
                    if (unknown != IntPtr.Zero) Marshal.Release(unknown);
                }
            }

            if (interfaceCount == 1 && soleRadio != IntPtr.Zero)
            {
                uint requestId;
                hr = DelegateAt<SetSoftwareRadioStateDelegate>(soleRadio, 5)(
                    soleRadio, radioState, out requestId);
                ThrowIfFailed(hr, "IMbnRadio.SetSoftwareRadioState");
                return new MbnSetResult { InterfaceId = soleInterfaceId, RequestId = requestId };
            }

            throw new InvalidOperationException(
                "The Quectel network adapter could not be matched to a Windows Mobile Broadband radio.");
        }
        finally
        {
            if (soleRadio != IntPtr.Zero) Marshal.Release(soleRadio);
            if (safeArray != IntPtr.Zero) SafeArrayDestroy(safeArray);
            if (manager != IntPtr.Zero) Marshal.Release(manager);
            if (uninitializeCom) CoUninitialize();
        }
    }

    public static string GetBindings()
    {
        Guid classId = MbnInterfaceManagerClassId;
        Guid managerIid = FindRegisteredGuid("Interface", "IMbnInterfaceManager");
        Guid interfaceIid = FindRegisteredGuid("Interface", "IMbnInterface");
        Guid registrationIid = FindRegisteredGuid("Interface", "IMbnRegistration");
        Guid radioIid = FindRegisteredGuid("Interface", "IMbnRadio");
        return "MbnInterfaceManager=" + classId.ToString("B") + Environment.NewLine +
               "IMbnInterfaceManager=" + managerIid.ToString("B") + Environment.NewLine +
               "IMbnInterface=" + interfaceIid.ToString("B") + Environment.NewLine +
               "IMbnRegistration=" + registrationIid.ToString("B") + Environment.NewLine +
               "IMbnRadio=" + radioIid.ToString("B");
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp
}

function Get-QuectelAdapter {
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
        $_.InterfaceDescription -match 'Quectel|RM520N' -or $_.Name -match 'Quectel|RM520N'
    })

    if ($adapters.Count -eq 0) {
        throw 'No Quectel/RM520N Windows network adapter was found.'
    }

    $present = @($adapters | Where-Object { $_.Status -ne 'Not Present' })
    if ($present.Count -gt 0) {
        return $present | Sort-Object @{ Expression = { if ($_.Status -eq 'Up') { 0 } else { 1 } } }, ifIndex | Select-Object -First 1
    }

    return $adapters | Select-Object -First 1
}

function Get-AdapterGuidText {
    param($Adapter)

    if ($null -ne $Adapter.InterfaceGuid -and -not [string]::IsNullOrWhiteSpace([string]$Adapter.InterfaceGuid)) {
        return [string]$Adapter.InterfaceGuid
    }
    return $null
}

function Format-HResult {
    param([int]$Value)
    return ('0x{0:X8}' -f ($Value -band 0xFFFFFFFFL))
}

function Get-DataClassCatalog {
    return @(
        [pscustomobject]@{ Bit = [uint32]0x00000001; Name = 'GPRS';       Display = 'GPRS (2G)';                Group = '2G'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]0x00000002; Name = 'EDGE';       Display = 'EDGE (2G)';                Group = '2G'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]0x00000004; Name = 'UMTS';       Display = 'UMTS (3G)';                Group = '3G'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]0x00000008; Name = 'HSDPA';      Display = 'HSDPA (3G downlink)';       Group = '3G'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]0x00000010; Name = 'HSUPA';      Display = 'HSUPA (3G uplink)';         Group = '3G'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]0x00000020; Name = 'LTE';        Display = 'LTE (4G)';                  Group = '4G'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]0x00000040; Name = '5G NSA';     Display = '5G NSA (LTE anchor)';       Group = '5G'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]0x00000080; Name = '5G SA';      Display = '5G SA';                     Group = '5G'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]0x00010000; Name = '1xRTT';      Display = '1xRTT (CDMA)';              Group = 'CDMA'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]0x00020000; Name = '1xEVDO';     Display = '1xEVDO (CDMA)';             Group = 'CDMA'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]0x00040000; Name = '1xEVDO Rev.A'; Display = '1xEVDO Rev.A (CDMA)';     Group = 'CDMA'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]0x00080000; Name = '1xEVDV';     Display = '1xEVDV (CDMA)';             Group = 'CDMA'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]0x00100000; Name = '3xRTT';      Display = '3xRTT (CDMA)';              Group = 'CDMA'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]0x00200000; Name = '1xEVDO Rev.B'; Display = '1xEVDO Rev.B (CDMA)';     Group = 'CDMA'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]0x00400000; Name = 'UMB';        Display = 'UMB (CDMA)';                Group = 'CDMA'; Selectable = $true }
        [pscustomobject]@{ Bit = [uint32]2147483648; Name = 'Custom';     Display = 'OEM custom data class';     Group = 'OEM'; Selectable = $false }
    )
}

function Get-SelectableSupportedMask {
    param([uint32]$SupportedMask)

    [uint32]$result = 0
    foreach ($item in Get-DataClassCatalog) {
        if ($item.Selectable -and (($SupportedMask -band [uint32]$item.Bit) -ne 0)) {
            $result = $result -bor [uint32]$item.Bit
        }
    }
    return $result
}

function Get-RatPresets {
    param([uint32]$SupportedMask)

    $presets = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[System.UInt32]'

    $addPreset = {
        param([string]$Id, [string]$Name, [uint32]$Mask, [string]$Description)
        if ($Mask -ne 0 -and $seen.Add($Mask)) {
            $presets.Add([pscustomobject]@{
                Id = $Id
                Name = $Name
                Mask = $Mask
                Description = $Description
            })
        }
    }

    [uint32]$allMask = Get-SelectableSupportedMask -SupportedMask $SupportedMask
    & $addPreset 'automatic' 'Automatic (all supported RATs)' $allMask 'Allows every standard data class reported by the modem.'

    if (($SupportedMask -band [uint32]0x20) -ne 0) {
        & $addPreset 'lte' 'LTE only' ([uint32]0x20) 'Excludes 2G, 3G, and 5G from the requested data classes.'
    }

    if (($SupportedMask -band [uint32]0x60) -eq [uint32]0x60) {
        & $addPreset 'nsa' 'LTE + 5G NSA' ([uint32]0x60) 'Recommended for NSA networks; LTE remains the anchor and fallback.'
    }

    if (($SupportedMask -band [uint32]0x80) -ne 0) {
        & $addPreset 'sa' '5G SA only' ([uint32]0x80) 'Requests standalone 5G without an LTE anchor.'
    }

    [uint32]$threeGMask = $SupportedMask -band [uint32]0x1C
    & $addPreset '3g' '3G / HSPA only' $threeGMask 'Uses the UMTS, HSDPA, and HSUPA classes reported by the modem.'

    [uint32]$twoGMask = $SupportedMask -band [uint32]0x03
    & $addPreset '2g' '2G only' $twoGMask 'Uses the GPRS and EDGE classes reported by the modem.'

    [uint32]$cdmaMask = $SupportedMask -band [uint32]0x007F0000
    & $addPreset 'cdma' 'CDMA family only' $cdmaMask 'Uses every supported 3GPP2/CDMA data class.'

    # Windows PowerShell 5.1 can throw "Argument types do not match" when a
    # generic List[object] is wrapped directly in @(...). Materialize a real
    # Object[] before returning it.
    return $presets.ToArray()
}

function Format-DataClass {
    param(
        [uint32]$Value,
        [int]$HResult = 0
    )

    if ($HResult -lt 0) {
        return 'Unavailable (' + (Format-HResult $HResult) + ')'
    }
    if ($Value -eq 0) {
        return 'Unknown / not registered'
    }

    $names = New-Object System.Collections.Generic.List[string]
    [uint32]$knownMask = 0
    foreach ($entry in Get-DataClassCatalog) {
        [uint32]$bit = $entry.Bit
        $knownMask = $knownMask -bor $bit
        if (($Value -band $bit) -ne 0) {
            $names.Add([string]$entry.Name)
        }
    }

    [uint32]$unknownBits = $Value -band ([uint32]::MaxValue -bxor $knownMask)
    if ($unknownBits -ne 0) {
        $names.Add(('Other 0x{0:X8}' -f $unknownBits))
    }
    return ($names -join ' + ') + (' [0x{0:X8}]' -f $Value)
}

function Test-Is5gDataClass {
    param([uint32]$Value)
    return (($Value -band [uint32]0xC0) -ne 0)
}

function Test-IsInvalidArgumentException {
    param([System.Exception]$Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ($current.HResult -eq -2147024809 -or $current.Message -match '(?i)0x80070057') {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Test-IsInvalidStateException {
    param([System.Exception]$Exception)

    $current = $Exception
    while ($null -ne $current) {
        # HRESULT_FROM_WIN32(ERROR_INVALID_STATE), documented by
        # IMbnRegistration.SetRegisterMode for an active data connection.
        if ($current.HResult -eq -2147019873 -or $current.Message -match '(?i)0x8007139F') {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Format-RegisterState {
    param([int]$Value, [int]$HResult)
    if ($HResult -lt 0) { return 'Unavailable (' + (Format-HResult $HResult) + ')' }
    $states = @('None', 'Deregistered', 'Searching', 'Home', 'Roaming', 'Partner', 'Denied')
    if ($Value -ge 0 -and $Value -lt $states.Count) { return $states[$Value] }
    return [string]$Value
}

function Format-RegistrationNetworkError {
    param([uint32]$Value, [int]$HResult)
    if ($HResult -lt 0) { return 'Unavailable (' + (Format-HResult $HResult) + ')' }
    if ($Value -eq 0) { return 'None [0]' }
    return '3GPP/network cause ' + $Value
}

function Format-RadioState {
    param([int]$Value, [int]$HResult)
    if ($HResult -lt 0) { return 'Unavailable (' + (Format-HResult $HResult) + ')' }
    if ($Value -eq 0) { return 'Off' }
    if ($Value -eq 1) { return 'On' }
    return 'Unknown [' + $Value + ']'
}

function Select-MbnInfo {
    param(
        [object[]]$Infos,
        [string]$PreferredGuid
    )

    if ($Infos.Count -eq 0) {
        throw 'Windows Mobile Broadband did not return an interface.'
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredGuid)) {
        $preferredParsed = [guid]::Empty
        [void][guid]::TryParse($PreferredGuid, [ref]$preferredParsed)
        foreach ($info in $Infos) {
            $infoParsed = [guid]::Empty
            if ([guid]::TryParse([string]$info.InterfaceId, [ref]$infoParsed) -and $infoParsed -eq $preferredParsed) {
                return $info
            }
        }
    }

    if ($Infos.Count -eq 1) {
        return $Infos[0]
    }

    throw 'Multiple mobile-broadband interfaces exist and the Quectel adapter could not be matched uniquely.'
}

function Get-RatStatus {
    Initialize-MbnNative
    $adapter = Get-QuectelAdapter
    $adapterGuid = Get-AdapterGuidText $adapter
    $infos = @([MbnNative]::GetInterfaces())
    $info = Select-MbnInfo -Infos $infos -PreferredGuid $adapterGuid

    [pscustomobject]@{
        AdapterName = [string]$adapter.Name
        AdapterDescription = [string]$adapter.InterfaceDescription
        AdapterStatus = [string]$adapter.Status
        InterfaceId = [string]$info.InterfaceId
        Provider = if ([string]::IsNullOrWhiteSpace($info.ProviderName)) { '(unavailable)' } else { [string]$info.ProviderName }
        RegisterState = Format-RegisterState -Value $info.RegisterState -HResult $info.RegisterStateHResult
        SupportedRat = Format-DataClass -Value $info.SupportedDataClasses -HResult $info.SupportedDataClassesHResult
        CurrentRat = Format-DataClass -Value $info.CurrentDataClass -HResult $info.CurrentDataClassHResult
        AvailableRat = Format-DataClass -Value $info.AvailableDataClasses -HResult $info.AvailableDataClassesHResult
        RegistrationNetworkError = Format-RegistrationNetworkError -Value $info.RegistrationNetworkError -HResult $info.RegistrationNetworkErrorHResult
        HardwareRadio = Format-RadioState -Value $info.HardwareRadioState -HResult $info.HardwareRadioStateHResult
        SoftwareRadio = Format-RadioState -Value $info.SoftwareRadioState -HResult $info.SoftwareRadioStateHResult
        SupportedMask = [uint32]$info.SupportedDataClasses
        SupportedHResult = [int]$info.SupportedDataClassesHResult
        RegisterStateCode = [int]$info.RegisterState
        RegisterStateHResult = [int]$info.RegisterStateHResult
        CurrentMask = [uint32]$info.CurrentDataClass
        CurrentHResult = [int]$info.CurrentDataClassHResult
        AvailableMask = [uint32]$info.AvailableDataClasses
        AvailableHResult = [int]$info.AvailableDataClassesHResult
        RegistrationNetworkErrorCode = [uint32]$info.RegistrationNetworkError
        RegistrationNetworkErrorHResult = [int]$info.RegistrationNetworkErrorHResult
        HardwareRadioState = [int]$info.HardwareRadioState
        HardwareRadioStateHResult = [int]$info.HardwareRadioStateHResult
        SoftwareRadioState = [int]$info.SoftwareRadioState
        SoftwareRadioStateHResult = [int]$info.SoftwareRadioStateHResult
    }
}

function Write-SwitchLog {
    param([string]$Message)
    try {
        $directory = Join-Path $env:ProgramData 'RM520N-RAT'
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
        $line = '{0:u} {1}' -f (Get-Date), $Message
        Add-Content -LiteralPath (Join-Path $directory 'switch.log') -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never block a RAT change.
    }
}

function Wait-WithMessagePump {
    param([int]$Milliseconds)

    for ($elapsed = 0; $elapsed -lt $Milliseconds; $elapsed += 250) {
        if ($null -ne ('System.Windows.Forms.Application' -as [type])) {
            [System.Windows.Forms.Application]::DoEvents()
        }
        $remaining = $Milliseconds - $elapsed
        Start-Sleep -Milliseconds ([Math]::Min(250, $remaining))
    }
}

function Set-CellularAutoConnectState {
    param(
        [string]$InterfaceName,
        [bool]$Enabled
    )

    $state = if ($Enabled) { 'autoon' } else { 'autooff' }
    $output = @(& "$env:SystemRoot\System32\netsh.exe" mbn set acstate "interface=$InterfaceName" "state=$state" 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = (($output | Out-String).Trim())
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = '(no text returned)' }
        throw ('netsh mbn set acstate ' + $state + ' failed with exit code ' + $exitCode + ': ' + $detail)
    }
}

function Set-CellularRadioState {
    param(
        [string]$InterfaceId,
        [string]$InterfaceName,
        [bool]$Enabled
    )

    $state = if ($Enabled) { 'on' } else { 'off' }
    $stateValue = if ($Enabled) { 1 } else { 0 }

    try {
        Initialize-MbnNative
        $result = [MbnNative]::SetSoftwareRadioState($InterfaceId, $stateValue)
        Write-SwitchLog ('IMbnRadio ' + $state + ' request accepted. RequestId=' + $result.RequestId)
        return $result
    }
    catch {
        $comError = $_.Exception.Message
        Write-SwitchLog ('NOTICE: IMbnRadio ' + $state + ' request failed; trying netsh: ' + $comError)
    }

    $output = @(& "$env:SystemRoot\System32\netsh.exe" mbn set powerstate "interface=$InterfaceName" "state=$state" 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = (($output | Out-String).Trim())
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = '(no text returned)' }
        throw ('Both IMbnRadio and netsh failed to request radio ' + $state + '. IMbnRadio: ' +
            $comError + '; netsh exit code ' + $exitCode + ': ' + $detail)
    }

    Write-SwitchLog ('netsh radio ' + $state + ' request accepted.')
    return [pscustomobject]@{ InterfaceId = $InterfaceId; RequestId = 0 }
}

function Wait-ForCellularRadioState {
    param(
        [bool]$Enabled,
        [int]$TimeoutSeconds = 10
    )

    $desiredState = if ($Enabled) { 1 } else { 0 }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $consecutiveMatches = 0
    do {
        Wait-WithMessagePump -Milliseconds 1000
        try {
            $status = Get-RatStatus
            $matches = $false
            if ($status.SoftwareRadioStateHResult -ge 0 -and
                $status.SoftwareRadioState -eq $desiredState) {
                if (-not $Enabled -or $status.HardwareRadioStateHResult -lt 0 -or
                    $status.HardwareRadioState -eq 1) {
                    $matches = $true
                }
            }

            # Registration itself proves that the effective radio is on if an
            # OEM build does not expose IMbnRadio state correctly.
            if ($Enabled -and $status.CurrentHResult -ge 0 -and $status.CurrentMask -ne 0) {
                $matches = $true
            }

            if ($matches) {
                $consecutiveMatches++
                # Avoid accepting a stale state while the previous asynchronous
                # OFF/ON operation is still completing.
                if ($consecutiveMatches -ge 2) { return $status }
            }
            else {
                $consecutiveMatches = 0
            }
        }
        catch {
            # The MBN interface can disappear briefly during a radio transition.
            $consecutiveMatches = 0
        }
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Restore-CellularRadioOn {
    param(
        [string]$InterfaceId,
        [string]$InterfaceName,
        [int]$Attempts = 3
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            [void](Set-CellularRadioState -InterfaceId $InterfaceId -InterfaceName $InterfaceName -Enabled $true)
        }
        catch {
            Write-SwitchLog ('WARNING: Radio-on request ' + $attempt + ' failed synchronously: ' + $_.Exception.Message)
        }

        $status = Wait-ForCellularRadioState -Enabled $true -TimeoutSeconds 10
        if ($null -ne $status) {
            Write-SwitchLog ('Cellular radio ON confirmed after request ' + $attempt + '.')
            return $status
        }
        Write-SwitchLog ('WARNING: Radio-on request ' + $attempt + ' was not confirmed; retrying.')
    }

    return $null
}

function Disconnect-CellularData {
    param([string]$InterfaceName)

    $output = @(& "$env:SystemRoot\System32\netsh.exe" mbn disconnect "interface=$InterfaceName" 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        # An already-disconnected interface can return a nonzero status. The
        # subsequent SetRegisterMode call is the authoritative state check.
        $detail = (($output | Out-String).Trim())
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = '(no text returned)' }
        Write-SwitchLog ('netsh disconnect returned exit code ' + $exitCode + ': ' + $detail)
    }
}

function Send-RatProgress {
    param([string]$Message)

    Write-SwitchLog $Message
    if (-not [string]::IsNullOrWhiteSpace($script:ProgressPath)) {
        try {
            $timestamped = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Message
            Add-Content -LiteralPath $script:ProgressPath -Value $timestamped -Encoding UTF8
        }
        catch {
            # GUI progress reporting must never interrupt the switch worker.
        }
    }
    if ($null -ne ('System.Windows.Forms.Application' -as [type])) {
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Test-CurrentRatMatchesRequest {
    param(
        [uint32]$CurrentMask,
        [uint32]$RequestedMask
    )

    if ($CurrentMask -eq 0 -or ($CurrentMask -band $RequestedMask) -eq 0) {
        return $false
    }
    [uint32]$outsideMask = $CurrentMask -band ([uint32]::MaxValue -bxor $RequestedMask)
    return ($outsideMask -eq 0)
}

function Invoke-RatChange {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$RequestedMask,

        [string]$RequestedLabel,

        [switch]$CycleRadio
    )

    if ($RequestedMask -eq 0) {
        throw 'Select at least one supported RAT before applying the change.'
    }
    if (($RequestedMask -band [uint32]2147483648) -ne 0) {
        throw 'The OEM Custom data-class bit cannot be selected without a vendor-specific data-class string.'
    }
    if (($RequestedMask -band [uint32]0x40) -ne 0 -and
        ($RequestedMask -band [uint32]0x20) -eq 0) {
        throw '5G NSA requires its LTE anchor. Select LTE together with 5G NSA.'
    }

    Initialize-MbnNative
    $initialStatus = Get-RatStatus
    if ($initialStatus.SupportedHResult -ge 0) {
        [uint32]$unsupportedMask = $RequestedMask -band ([uint32]::MaxValue -bxor $initialStatus.SupportedMask)
        if ($unsupportedMask -ne 0) {
            throw ('The modem does not report support for requested data-class bits 0x{0:X8}.' -f $unsupportedMask)
        }
    }

    $adapter = Get-QuectelAdapter
    $adapterGuid = Get-AdapterGuidText $adapter
    $interfaceName = [string]$adapter.Name
    $label = if ([string]::IsNullOrWhiteSpace($RequestedLabel)) {
        (Format-DataClass -Value $RequestedMask) -replace '\s+\[0x[0-9A-F]{8}\]$', ''
    }
    else {
        $RequestedLabel
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    $candidates.Add([pscustomobject]@{
        Mask = $RequestedMask
        Description = $label
    })

    # A small number of drivers reject LTE|NSA but accept the NSA class alone.
    # Keep this compatibility fallback only for the known 0x60 preset; custom
    # combinations are always submitted exactly as selected.
    if ($RequestedMask -eq [uint32]0x60) {
        $candidates.Add([pscustomobject]@{
            Mask = [uint32]0x40
            Description = '5G NSA (driver fallback)'
        })
    }

    $setResult = $null
    $lastSetError = $null
    [uint32]$acceptedMask = 0
    $acceptedDescription = $null
    $autoConnectNeedsRestore = $false
    $radioNeedsRestore = $false
    [uint32]$requested5gMask = $RequestedMask -band [uint32]0xC0
    $shouldCycleRadio = $CycleRadio.IsPresent -or $requested5gMask -ne 0

    Send-RatProgress -Message ('Starting ' + $label + (' [0x{0:X8}]' -f $RequestedMask) + ' on ' + $interfaceName)

    try {
        Send-RatProgress -Message 'Disconnecting cellular data and preparing the registration request...'
        try {
            Set-CellularAutoConnectState -InterfaceName $interfaceName -Enabled $false
            $autoConnectNeedsRestore = $true
            Write-SwitchLog 'Cellular auto-connect paused.'
        }
        catch {
            Write-SwitchLog ('NOTICE: autooff is unavailable; continuing with direct disconnect: ' + $_.Exception.Message)
        }
        Disconnect-CellularData -InterfaceName $interfaceName
        Wait-WithMessagePump -Milliseconds 600

        foreach ($candidate in $candidates) {
            [uint32]$candidateMask = $candidate.Mask
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    $attemptSuffix = if ($attempt -gt 1) { ' (attempt ' + $attempt + ' of 3)' } else { '' }
                    Send-RatProgress -Message (
                        'Submitting ' + $candidate.Description + (' [0x{0:X8}]' -f $candidateMask) +
                        $attemptSuffix + '...')
                    $setResult = [MbnNative]::SetPreferredDataClass($adapterGuid, $candidateMask)
                    $acceptedMask = $candidateMask
                    $acceptedDescription = [string]$candidate.Description
                    break
                }
                catch {
                    $lastSetError = $_.Exception
                    if ((Test-IsInvalidStateException -Exception $_.Exception) -and $attempt -lt 3) {
                        Send-RatProgress -Message 'Windows reconnected cellular data; disconnecting and retrying...'
                        Disconnect-CellularData -InterfaceName $interfaceName
                        Wait-WithMessagePump -Milliseconds 400
                        continue
                    }
                    if ($candidates.Count -gt 1 -and
                        (Test-IsInvalidArgumentException -Exception $_.Exception)) {
                        Send-RatProgress -Message (
                            'Driver rejected 0x' + $candidateMask.ToString('X8') + '; trying the NSA compatibility fallback.')
                        break
                    }
                    throw
                }
            }
            if ($null -ne $setResult) { break }
        }

        if ($null -eq $setResult) {
            $detail = if ($null -eq $lastSetError) { 'No additional error was returned.' } else { $lastSetError.Message }
            throw ('The WWAN driver rejected the RAT request 0x{0:X8}. Last error: {1}' -f $RequestedMask, $detail)
        }

        $acceptedDataClass = $acceptedDescription + (' [0x{0:X8}]' -f $acceptedMask)
        Send-RatProgress -Message (
            'Request accepted (ID ' + $setResult.RequestId + '). Waiting for asynchronous completion...')
        Wait-WithMessagePump -Milliseconds 8000

        if ($shouldCycleRadio) {
            Send-RatProgress -Message 'Cycling the cellular radio to force registration with the new RAT preference...'
            $radioNeedsRestore = $true
            $radioOffRequestAccepted = $false
            try {
                [void](Set-CellularRadioState -InterfaceId $adapterGuid -InterfaceName $interfaceName -Enabled $false)
                $radioOffRequestAccepted = $true
            }
            catch {
                Write-SwitchLog ('WARNING: Radio-off request failed; forcing radio ON for safety: ' + $_.Exception.Message)
            }

            if ($radioOffRequestAccepted) {
                $radioOffStatus = Wait-ForCellularRadioState -Enabled $false -TimeoutSeconds 8
                if ($null -ne $radioOffStatus) {
                    Write-SwitchLog 'Cellular radio OFF confirmed.'
                    Wait-WithMessagePump -Milliseconds 2000
                }
                else {
                    Write-SwitchLog 'WARNING: Radio OFF was not confirmed; proceeding directly to verified ON recovery.'
                }
            }

            Send-RatProgress -Message 'Turning the cellular radio back on and verifying the effective state...'
            $radioOnStatus = Restore-CellularRadioOn -InterfaceId $adapterGuid -InterfaceName $interfaceName -Attempts 3
            if ($null -eq $radioOnStatus) {
                throw 'The RAT preference was applied, but the cellular radio still reports OFF after three recovery attempts. Turn Cellular on once in Windows Settings.'
            }
            $radioNeedsRestore = $false
            Write-SwitchLog 'Cellular radio cycle completed with ON state confirmed.'
            Wait-WithMessagePump -Milliseconds 5000
        }

        Send-RatProgress -Message 'Restoring connectivity and waiting for network reselection...'
        if ($autoConnectNeedsRestore) {
            try {
                Set-CellularAutoConnectState -InterfaceName $interfaceName -Enabled $true
                $autoConnectNeedsRestore = $false
                Write-SwitchLog 'Cellular auto-connect restored.'
            }
            catch {
                Write-SwitchLog ('NOTICE: autoon is unavailable; continuing with network verification: ' + $_.Exception.Message)
            }
        }

        $verificationSeconds = if ($requested5gMask -ne 0) { 45 } else { 30 }
        $deadline = (Get-Date).AddSeconds($verificationSeconds)
        $status = $null
        do {
            Wait-WithMessagePump -Milliseconds 2000
            try {
                $status = Get-RatStatus
                if ($requested5gMask -ne 0) {
                    $currentHasRequested5g = ($status.CurrentHResult -ge 0 -and
                        ($status.CurrentMask -band $requested5gMask) -ne 0)
                    $availableHasRequested5g = ($status.AvailableHResult -ge 0 -and
                        ($status.AvailableMask -band $requested5gMask) -ne 0)
                    if ($currentHasRequested5g -or $availableHasRequested5g) { break }
                }
                elseif ($status.CurrentHResult -ge 0 -and
                    (Test-CurrentRatMatchesRequest -CurrentMask $status.CurrentMask -RequestedMask $RequestedMask)) {
                    break
                }
            }
            catch {
                # Registration can be briefly unavailable during reselection.
            }
        } while ((Get-Date) -lt $deadline)

        if ($null -eq $status) {
            $status = Get-RatStatus
        }
    }
    finally {
        if ($radioNeedsRestore) {
            try {
                $restoredRadioStatus = Restore-CellularRadioOn -InterfaceId $adapterGuid -InterfaceName $interfaceName -Attempts 2
                if ($null -ne $restoredRadioStatus) {
                    $radioNeedsRestore = $false
                    Write-SwitchLog 'Cellular radio ON confirmed after an interrupted or failed switch.'
                }
                else {
                    Write-SwitchLog 'CRITICAL: Cellular radio remains OFF or unverified after final recovery attempts.'
                }
            }
            catch {
                Write-SwitchLog ('WARNING: Could not restore cellular radio: ' + $_.Exception.Message)
            }
        }
        if ($autoConnectNeedsRestore) {
            try {
                Set-CellularAutoConnectState -InterfaceName $interfaceName -Enabled $true
                $autoConnectNeedsRestore = $false
                Write-SwitchLog 'Auto-connect restored after an interrupted or failed switch.'
            }
            catch {
                Write-SwitchLog ('WARNING: Could not restore auto-connect: ' + $_.Exception.Message)
            }
        }
    }

    if ($requested5gMask -ne 0) {
        if ($status.CurrentHResult -ge 0 -and ($status.CurrentMask -band $requested5gMask) -ne 0) {
            $verification = '5G registration confirmed: ' + $status.CurrentRat
            $verificationKind = 'confirmed'
        }
        elseif ($status.AvailableHResult -ge 0 -and ($status.AvailableMask -band $requested5gMask) -ne 0) {
            $verification = 'Requested 5G is available; the current connection is still ' + $status.CurrentRat + '.'
            $verificationKind = 'available'
        }
        else {
            $verification = 'WARNING: the request was submitted, but the requested 5G class was not reported within 45 seconds.'
            $verificationKind = 'unconfirmed'
        }
    }
    elseif ($status.CurrentHResult -ge 0 -and
        (Test-CurrentRatMatchesRequest -CurrentMask $status.CurrentMask -RequestedMask $RequestedMask)) {
        $verification = 'Selected RAT confirmed: ' + $status.CurrentRat
        $verificationKind = 'confirmed'
    }
    else {
        $verification = 'WARNING: the requested RAT set was not confirmed within 30 seconds. Check Actual RAT.'
        $verificationKind = 'unconfirmed'
    }

    Send-RatProgress -Message ('Completed: ' + $verification)
    Write-SwitchLog ('Requested=' + $acceptedDataClass + ' Actual=' + $status.CurrentRat +
        ' Available=' + $status.AvailableRat)
    return [pscustomobject]@{
        Target = $label
        RequestId = $setResult.RequestId
        RequestedMask = $RequestedMask
        AcceptedMask = $acceptedMask
        RequestedDataClass = $acceptedDataClass
        RadioCycled = $shouldCycleRadio
        VerificationKind = $verificationKind
        Verification = $verification
        Status = $status
    }
}

function Format-StatusText {
    param($Status)
    return @(
        'Adapter: ' + $Status.AdapterName,
        'Device: ' + $Status.AdapterDescription,
        'Adapter state: ' + $Status.AdapterStatus,
        'Provider: ' + $Status.Provider,
        'Registration: ' + $Status.RegisterState,
        'Radio: hardware ' + $Status.HardwareRadio + ' / software ' + $Status.SoftwareRadio,
        'Device-supported RAT: ' + $Status.SupportedRat,
        'Actual RAT: ' + $Status.CurrentRat,
        'Available RAT: ' + $Status.AvailableRat,
        'Last registration error: ' + $Status.RegistrationNetworkError,
        'MBN Interface ID: ' + $Status.InterfaceId
    ) -join [Environment]::NewLine
}

function Get-DiagnosticsText {
    $sections = New-Object System.Collections.Generic.List[string]

    $addSection = {
        param([string]$Title, [scriptblock]$Body)
        $sections.Add('=== ' + $Title + ' ===')
        try {
            $rendered = (& $Body | Out-String -Width 240).TrimEnd()
            if ([string]::IsNullOrWhiteSpace($rendered)) { $rendered = '(no output)' }
            $sections.Add($rendered)
        }
        catch {
            $sections.Add('ERROR: ' + $_.Exception.Message)
        }
        $sections.Add('')
    }

    & $addSection 'Tool / Windows' {
        [pscustomobject]@{
            ToolVersion = $script:ToolVersion
            Time = (Get-Date).ToString('u')
            Windows = (Get-CimInstance Win32_OperatingSystem).Caption
            Version = [Environment]::OSVersion.VersionString
            PowerShell = $PSVersionTable.PSVersion.ToString()
            IsAdministrator = Test-IsAdministrator
        } | Format-List
    }

    & $addSection 'Quectel adapter' {
        Get-QuectelAdapter |
            Format-List Name, InterfaceDescription, Status, ifIndex, InterfaceGuid, DriverInformation
    }

    & $addSection 'Windows WWAN service' {
        Get-Service -Name WwanSvc | Format-List Name, Status, StartType
    }

    & $addSection 'netsh MBN control state' {
        $interfaceName = [string](Get-QuectelAdapter).Name
        $netsh = "$env:SystemRoot\System32\netsh.exe"

        $autoOutput = @(& $netsh mbn show acstate "interface=$interfaceName" 2>&1)
        $autoExitCode = $LASTEXITCODE
        $autoText = (($autoOutput | Out-String).Trim())
        if ([string]::IsNullOrWhiteSpace($autoText)) { $autoText = '(no text returned)' }

        $radioOutput = @(& $netsh mbn show radio "interface=$interfaceName" 2>&1)
        $radioExitCode = $LASTEXITCODE
        $radioText = (($radioOutput | Out-String).Trim())
        if ([string]::IsNullOrWhiteSpace($radioText)) { $radioText = '(no text returned)' }

        [pscustomobject]@{
            Interface = $interfaceName
            AutoConnectExitCode = $autoExitCode
            AutoConnectOutput = $autoText
            RadioExitCode = $radioExitCode
            RadioOutput = $radioText
        } | Format-List
    }

    & $addSection 'Windows MBN COM bindings' {
        Initialize-MbnNative
        [MbnNative]::GetBindings()
    }

    & $addSection 'RAT status' {
        Format-StatusText (Get-RatStatus)
    }

    & $addSection 'Recent switch log' {
        $logPath = Join-Path $env:ProgramData 'RM520N-RAT\switch.log'
        if (Test-Path -LiteralPath $logPath) {
            Get-Content -LiteralPath $logPath -Tail 60
        }
        else {
            '(no switch log)'
        }
    }

    & $addSection 'Quectel PnP drivers' {
        Get-CimInstance Win32_PnPSignedDriver |
            Where-Object { $_.DeviceName -match 'Quectel|RM520N' } |
            Sort-Object DeviceName |
            Format-Table DeviceName, InfName, DriverVersion, DriverProviderName -AutoSize
    }

    & $addSection 'NetAdapter advanced properties' {
        Get-NetAdapterAdvancedProperty -Name (Get-QuectelAdapter).Name -AllProperties -ErrorAction SilentlyContinue |
            Format-Table DisplayName, DisplayValue, RegistryKeyword, RegistryValue -AutoSize
    }

    return ($sections -join [Environment]::NewLine).TrimEnd()
}

function Find-GuiControl {
    param(
        $Form,
        [string]$Name
    )

    $matches = @($Form.Controls.Find($Name, $true))
    if ($matches.Count -eq 0) {
        throw ('GUI control was not found: ' + $Name)
    }
    return $matches[0]
}

function Get-CheckedRatMask {
    param($List)

    [uint32]$mask = 0
    for ($index = 0; $index -lt $List.Items.Count; $index++) {
        if ($List.GetItemChecked($index)) {
            $mask = $mask -bor [uint32]$List.Items[$index].Bit
        }
    }
    return $mask
}

function Set-CheckedRatMask {
    param(
        $List,
        [uint32]$Mask
    )

    for ($index = 0; $index -lt $List.Items.Count; $index++) {
        [uint32]$bit = $List.Items[$index].Bit
        $List.SetItemChecked($index, (($Mask -band $bit) -ne 0))
    }
}

function Update-GuiSelectionSummary {
    param($Form)

    $list = Find-GuiControl -Form $Form -Name 'RatList'
    $summary = Find-GuiControl -Form $Form -Name 'SelectionSummary'
    $maskLabel = Find-GuiControl -Form $Form -Name 'MaskLabel'
    $applyButton = Find-GuiControl -Form $Form -Name 'ApplyButton'
    $forceCycle = Find-GuiControl -Form $Form -Name 'ForceCycleCheck'
    [uint32]$mask = Get-CheckedRatMask -List $list

    if (($mask -band [uint32]0xC0) -ne 0) {
        $forceCycle.Checked = $true
        $forceCycle.Enabled = $false
    }
    else {
        $forceCycle.Enabled = -not [bool]$Form.Tag.Busy
    }

    $maskLabel.Text = 'Request mask  0x{0:X8}' -f $mask
    if ($mask -eq 0) {
        $summary.Text = 'Select at least one RAT.'
        $summary.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
        $applyButton.Enabled = $false
        return
    }

    if (($mask -band [uint32]0x40) -ne 0 -and ($mask -band [uint32]0x20) -eq 0) {
        $summary.Text = '5G NSA also requires LTE as its anchor.'
        $summary.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
        $applyButton.Enabled = $false
        return
    }

    $summary.Text = Format-DataClass -Value $mask
    $summary.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
    $applyButton.Enabled = -not [bool]$Form.Tag.Busy
}

function Set-GuiBusyState {
    param(
        $Form,
        [bool]$Busy
    )

    $Form.Tag.Busy = $Busy
    (Find-GuiControl -Form $Form -Name 'PresetCombo').Enabled = -not $Busy
    (Find-GuiControl -Form $Form -Name 'RatList').Enabled = -not $Busy
    (Find-GuiControl -Form $Form -Name 'ForceCycleCheck').Enabled = -not $Busy
    (Find-GuiControl -Form $Form -Name 'RefreshButton').Enabled = -not $Busy
    (Find-GuiControl -Form $Form -Name 'QuickLteButton').Enabled =
        (-not $Busy -and [bool]$Form.Tag.QuickLteAvailable)
    (Find-GuiControl -Form $Form -Name 'QuickNsaButton').Enabled =
        (-not $Busy -and [bool]$Form.Tag.QuickNsaAvailable)

    $progressBar = Find-GuiControl -Form $Form -Name 'ProgressBar'
    if ($Busy) {
        $progressBar.Style = 'Marquee'
        $progressBar.MarqueeAnimationSpeed = 28
        $progressBar.Visible = $true
        (Find-GuiControl -Form $Form -Name 'ApplyButton').Enabled = $false
    }
    else {
        $progressBar.MarqueeAnimationSpeed = 0
        $progressBar.Visible = $false
        Update-GuiSelectionSummary -Form $Form
    }
}

function Refresh-GuiStatus {
    param($Form)

    $statusBox = Find-GuiControl -Form $Form -Name 'StatusBox'
    $headline = Find-GuiControl -Form $Form -Name 'StatusHeadline'
    $refreshButton = Find-GuiControl -Form $Form -Name 'RefreshButton'
    try {
        $refreshButton.Enabled = $false
        $headline.Text = 'Reading modem state...'
        $headline.ForeColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
        [System.Windows.Forms.Application]::DoEvents()

        $status = Get-RatStatus
        $statusBox.Text = Format-StatusText $status
        $headline.Text = $status.RegisterState + '  |  ' + $status.CurrentRat
        $headline.ForeColor = if ($status.RegisterStateCode -in @(3, 4, 5)) {
            [System.Drawing.Color]::FromArgb(22, 101, 52)
        }
        else {
            [System.Drawing.Color]::FromArgb(180, 83, 9)
        }

        if ($status.SupportedHResult -lt 0) {
            throw 'The modem did not return its supported RAT mask.'
        }

        if ($Form.Tag.SupportedMask -ne [uint32]$status.SupportedMask) {
            $Form.Tag.SupportedMask = [uint32]$status.SupportedMask
            $ratList = Find-GuiControl -Form $Form -Name 'RatList'
            $presetCombo = Find-GuiControl -Form $Form -Name 'PresetCombo'

            $Form.Tag.SuppressSelectionEvents = $true
            try {
                $ratList.BeginUpdate()
                $ratList.Items.Clear()
                foreach ($item in Get-DataClassCatalog) {
                    if ($item.Selectable -and
                        (($status.SupportedMask -band [uint32]$item.Bit) -ne 0)) {
                        [void]$ratList.Items.Add($item, $false)
                    }
                }

                $presetCombo.Items.Clear()
                $presets = @(Get-RatPresets -SupportedMask $status.SupportedMask)
                foreach ($preset in $presets) {
                    [void]$presetCombo.Items.Add($preset)
                }
                $Form.Tag.QuickLteAvailable =
                    (@($presets | Where-Object { $_.Id -eq 'lte' }).Count -gt 0)
                $Form.Tag.QuickNsaAvailable =
                    (@($presets | Where-Object { $_.Id -eq 'nsa' }).Count -gt 0)
                (Find-GuiControl -Form $Form -Name 'QuickLteButton').Enabled = $Form.Tag.QuickLteAvailable
                (Find-GuiControl -Form $Form -Name 'QuickNsaButton').Enabled = $Form.Tag.QuickNsaAvailable

                $defaultPreset = $null
                if (($status.CurrentMask -band [uint32]0x40) -ne 0) {
                    $defaultPreset = $presets | Where-Object { $_.Id -eq 'nsa' } | Select-Object -First 1
                }
                elseif ($status.CurrentMask -eq [uint32]0x20) {
                    $defaultPreset = $presets | Where-Object { $_.Id -eq 'lte' } | Select-Object -First 1
                }
                if ($null -eq $defaultPreset) {
                    $defaultPreset = $presets | Select-Object -First 1
                }

                if ($null -ne $defaultPreset) {
                    $presetCombo.SelectedItem = $defaultPreset
                    Set-CheckedRatMask -List $ratList -Mask ([uint32]$defaultPreset.Mask)
                    (Find-GuiControl -Form $Form -Name 'ForceCycleCheck').Checked =
                        (([uint32]$defaultPreset.Mask -band [uint32]0xC0) -ne 0)
                }
            }
            finally {
                $ratList.EndUpdate()
                $Form.Tag.SuppressSelectionEvents = $false
            }
            Update-GuiSelectionSummary -Form $Form
        }
    }
    catch {
        $headline.Text = 'Unable to read modem state'
        $headline.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
        $statusBox.Text = 'ERROR (v' + $script:ToolVersion + ')' + [Environment]::NewLine +
            $_.Exception.Message + [Environment]::NewLine +
            [string]$_.InvocationInfo.PositionMessage
    }
    finally {
        if (-not $Form.Tag.Busy) {
            $refreshButton.Enabled = $true
        }
    }
}

function ConvertTo-NativeQuotedArgument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Start-GuiRatWorker {
    param($Form)

    $ratList = Find-GuiControl -Form $Form -Name 'RatList'
    [uint32]$mask = Get-CheckedRatMask -List $ratList
    if ($mask -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            $Form,
            'Select at least one supported RAT.',
            'Nothing to apply',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    if (($mask -band [uint32]0x40) -ne 0 -and ($mask -band [uint32]0x20) -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            $Form,
            '5G NSA requires LTE as its anchor. Select LTE together with 5G NSA.',
            'Invalid RAT combination',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $jobDirectory = Join-Path $env:TEMP 'RM520N-RAT-Switcher'
    if (-not (Test-Path -LiteralPath $jobDirectory)) {
        New-Item -Path $jobDirectory -ItemType Directory -Force | Out-Null
    }
    $jobId = [guid]::NewGuid().ToString('N')
    $progressFile = Join-Path $jobDirectory ($jobId + '.progress.log')
    $resultFile = Join-Path $jobDirectory ($jobId + '.result.json')
    Set-Content -LiteralPath $progressFile -Value '' -Encoding UTF8

    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
        (ConvertTo-NativeQuotedArgument -Value $script:ScriptPath) +
        ' -Mode apply -RatMask ' + $mask +
        ' -ResultPath ' + (ConvertTo-NativeQuotedArgument -Value $resultFile) +
        ' -ProgressPath ' + (ConvertTo-NativeQuotedArgument -Value $progressFile)
    if ((Find-GuiControl -Form $Form -Name 'ForceCycleCheck').Checked) {
        $arguments += ' -ForceRadioCycle'
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShell
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

    try {
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'The background worker process could not be started.'
        }

        $Form.Tag.Process = $process
        $Form.Tag.ProgressPath = $progressFile
        $Form.Tag.ResultPath = $resultFile
        $Form.Tag.LastProgress = ''
        (Find-GuiControl -Form $Form -Name 'StatusBox').Text =
            'Applying ' + (Format-DataClass -Value $mask) + '...' + [Environment]::NewLine +
            'The window remains responsive while Windows and the modem re-register.'
        (Find-GuiControl -Form $Form -Name 'StatusHeadline').Text = 'Applying RAT preference'
        (Find-GuiControl -Form $Form -Name 'StatusHeadline').ForeColor =
            [System.Drawing.Color]::FromArgb(37, 99, 235)
        (Find-GuiControl -Form $Form -Name 'ProgressLabel').Text = 'Starting background worker...'
        Set-GuiBusyState -Form $Form -Busy $true
    }
    catch {
        Remove-Item -LiteralPath $progressFile, $resultFile -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Complete-GuiRatWorker {
    param($Form)

    $statusBox = Find-GuiControl -Form $Form -Name 'StatusBox'
    $headline = Find-GuiControl -Form $Form -Name 'StatusHeadline'
    $progressLabel = Find-GuiControl -Form $Form -Name 'ProgressLabel'
    $exitCode = $Form.Tag.Process.ExitCode

    try {
        if (-not (Test-Path -LiteralPath $Form.Tag.ResultPath)) {
            throw ('The worker exited with code ' + $exitCode + ' without returning a result.')
        }
        $payload = Get-Content -LiteralPath $Form.Tag.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $payload.Success) {
            throw ([string]$payload.Error)
        }

        $statusBox.Text = 'Request accepted (ID ' + $payload.Result.RequestId + ', ' +
            $payload.Result.RequestedDataClass + ')' + [Environment]::NewLine +
            $payload.Result.Verification + [Environment]::NewLine +
            [Environment]::NewLine + (Format-StatusText $payload.Result.Status)
        $progressLabel.Text = 'Completed'
        if ($payload.Result.VerificationKind -eq 'confirmed') {
            $headline.Text = 'RAT change confirmed'
            $headline.ForeColor = [System.Drawing.Color]::FromArgb(22, 101, 52)
        }
        elseif ($payload.Result.VerificationKind -eq 'available') {
            $headline.Text = 'RAT enabled; waiting on network selection'
            $headline.ForeColor = [System.Drawing.Color]::FromArgb(180, 83, 9)
        }
        else {
            $headline.Text = 'Request completed but was not confirmed'
            $headline.ForeColor = [System.Drawing.Color]::FromArgb(180, 83, 9)
        }
    }
    catch {
        $headline.Text = 'RAT change failed'
        $headline.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
        $statusBox.Text = 'ERROR (v' + $script:ToolVersion + ')' + [Environment]::NewLine +
            $_.Exception.Message + [Environment]::NewLine +
            'Run Diagnostics.cmd and copy its output if this persists.'
        $progressLabel.Text = 'Failed'
    }
    finally {
        if ($null -ne $Form.Tag.Process) {
            $Form.Tag.Process.Dispose()
        }
        Remove-Item -LiteralPath $Form.Tag.ProgressPath, $Form.Tag.ResultPath -Force -ErrorAction SilentlyContinue
        $Form.Tag.Process = $null
        $Form.Tag.ProgressPath = $null
        $Form.Tag.ResultPath = $null
        Set-GuiBusyState -Form $Form -Busy $false
    }
}

function Update-GuiWorker {
    param($Form)

    if (-not $Form.Tag.Busy -or $null -eq $Form.Tag.Process) {
        return
    }

    if (Test-Path -LiteralPath $Form.Tag.ProgressPath) {
        try {
            $progressText = (Get-Content -LiteralPath $Form.Tag.ProgressPath -Raw -Encoding UTF8).Trim()
            if (-not [string]::IsNullOrWhiteSpace($progressText) -and
                $progressText -ne $Form.Tag.LastProgress) {
                $Form.Tag.LastProgress = $progressText
                $lines = @($progressText -split '\r?\n')
                (Find-GuiControl -Form $Form -Name 'ProgressLabel').Text = $lines[-1]
                $statusBox = Find-GuiControl -Form $Form -Name 'StatusBox'
                $statusBox.Text = 'RAT change in progress' + [Environment]::NewLine +
                    [Environment]::NewLine + $progressText
                $statusBox.SelectionStart = $statusBox.TextLength
                $statusBox.ScrollToCaret()
            }
        }
        catch {
            # The worker can be writing the file while the GUI timer reads it.
        }
    }

    if ($Form.Tag.Process.HasExited) {
        Complete-GuiRatWorker -Form $Form
    }
}

function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Quectel RM520N RAT Switcher v' + $script:ToolVersion
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object System.Drawing.Size(920, 680)
    $form.MinimumSize = New-Object System.Drawing.Size(860, 650)
    $form.BackColor = [System.Drawing.Color]::FromArgb(244, 246, 249)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.Tag = @{
        Busy = $false
        Process = $null
        ProgressPath = $null
        ResultPath = $null
        LastProgress = ''
        SupportedMask = [uint32]0
        SuppressSelectionEvents = $false
        QuickLteAvailable = $false
        QuickNsaAvailable = $false
    }

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 78
    $header.BackColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
    $form.Controls.Add($header)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'RM520N RAT Switcher'
    $title.ForeColor = [System.Drawing.Color]::White
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
    $title.Location = New-Object System.Drawing.Point(22, 13)
    $title.AutoSize = $true
    $header.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = 'Windows MBN data-class control  |  v' + $script:ToolVersion
    $subtitle.ForeColor = [System.Drawing.Color]::FromArgb(156, 163, 175)
    $subtitle.Location = New-Object System.Drawing.Point(25, 48)
    $subtitle.AutoSize = $true
    $header.Controls.Add($subtitle)

    $selectionPanel = New-Object System.Windows.Forms.Panel
    $selectionPanel.Location = New-Object System.Drawing.Point(20, 98)
    $selectionPanel.Size = New-Object System.Drawing.Size(360, 474)
    $selectionPanel.Anchor = 'Top,Bottom,Left'
    $selectionPanel.BackColor = [System.Drawing.Color]::White
    $selectionPanel.BorderStyle = 'FixedSingle'
    $form.Controls.Add($selectionPanel)

    $selectionTitle = New-Object System.Windows.Forms.Label
    $selectionTitle.Text = 'Network mode'
    $selectionTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
    $selectionTitle.Location = New-Object System.Drawing.Point(18, 15)
    $selectionTitle.AutoSize = $true
    $selectionPanel.Controls.Add($selectionTitle)

    $selectionHelp = New-Object System.Windows.Forms.Label
    $selectionHelp.Text = 'Choose a preset or select any RAT classes reported by the modem.'
    $selectionHelp.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
    $selectionHelp.Location = New-Object System.Drawing.Point(20, 43)
    $selectionHelp.Size = New-Object System.Drawing.Size(318, 38)
    $selectionPanel.Controls.Add($selectionHelp)

    $presetCombo = New-Object System.Windows.Forms.ComboBox
    $presetCombo.Name = 'PresetCombo'
    $presetCombo.DropDownStyle = 'DropDownList'
    $presetCombo.DisplayMember = 'Name'
    $presetCombo.Location = New-Object System.Drawing.Point(20, 83)
    $presetCombo.Size = New-Object System.Drawing.Size(318, 28)
    $selectionPanel.Controls.Add($presetCombo)

    $quickLteButton = New-Object System.Windows.Forms.Button
    $quickLteButton.Name = 'QuickLteButton'
    $quickLteButton.Tag = 'lte'
    $quickLteButton.Text = 'LTE only'
    $quickLteButton.FlatStyle = 'Flat'
    $quickLteButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(209, 213, 219)
    $quickLteButton.Location = New-Object System.Drawing.Point(20, 120)
    $quickLteButton.Size = New-Object System.Drawing.Size(153, 32)
    $quickLteButton.Enabled = $false
    $selectionPanel.Controls.Add($quickLteButton)

    $quickNsaButton = New-Object System.Windows.Forms.Button
    $quickNsaButton.Name = 'QuickNsaButton'
    $quickNsaButton.Tag = 'nsa'
    $quickNsaButton.Text = 'LTE + 5G NSA'
    $quickNsaButton.FlatStyle = 'Flat'
    $quickNsaButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(209, 213, 219)
    $quickNsaButton.Location = New-Object System.Drawing.Point(185, 120)
    $quickNsaButton.Size = New-Object System.Drawing.Size(153, 32)
    $quickNsaButton.Enabled = $false
    $selectionPanel.Controls.Add($quickNsaButton)

    $ratList = New-Object System.Windows.Forms.CheckedListBox
    $ratList.Name = 'RatList'
    $ratList.DisplayMember = 'Display'
    $ratList.CheckOnClick = $true
    $ratList.IntegralHeight = $false
    $ratList.BorderStyle = 'FixedSingle'
    $ratList.Location = New-Object System.Drawing.Point(20, 163)
    $ratList.Size = New-Object System.Drawing.Size(318, 168)
    $ratList.Anchor = 'Top,Bottom,Left,Right'
    $selectionPanel.Controls.Add($ratList)

    $selectionSummary = New-Object System.Windows.Forms.Label
    $selectionSummary.Name = 'SelectionSummary'
    $selectionSummary.Location = New-Object System.Drawing.Point(20, 343)
    $selectionSummary.Size = New-Object System.Drawing.Size(318, 36)
    $selectionSummary.Anchor = 'Bottom,Left,Right'
    $selectionPanel.Controls.Add($selectionSummary)

    $maskLabel = New-Object System.Windows.Forms.Label
    $maskLabel.Name = 'MaskLabel'
    $maskLabel.Text = 'Request mask  0x00000000'
    $maskLabel.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $maskLabel.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)
    $maskLabel.Location = New-Object System.Drawing.Point(20, 382)
    $maskLabel.AutoSize = $true
    $maskLabel.Anchor = 'Bottom,Left'
    $selectionPanel.Controls.Add($maskLabel)

    $forceCycle = New-Object System.Windows.Forms.CheckBox
    $forceCycle.Name = 'ForceCycleCheck'
    $forceCycle.Text = 'Force network re-registration'
    $forceCycle.Location = New-Object System.Drawing.Point(20, 410)
    $forceCycle.AutoSize = $true
    $forceCycle.Anchor = 'Bottom,Left'
    $selectionPanel.Controls.Add($forceCycle)

    $cycleHelp = New-Object System.Windows.Forms.Label
    $cycleHelp.Text = 'Required for 5G; optional for legacy RATs. Only the cellular radio is cycled.'
    $cycleHelp.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
    $cycleHelp.Location = New-Object System.Drawing.Point(39, 434)
    $cycleHelp.Size = New-Object System.Drawing.Size(299, 33)
    $cycleHelp.Anchor = 'Bottom,Left,Right'
    $selectionPanel.Controls.Add($cycleHelp)

    $statusPanel = New-Object System.Windows.Forms.Panel
    $statusPanel.Location = New-Object System.Drawing.Point(400, 98)
    $statusPanel.Size = New-Object System.Drawing.Size(500, 474)
    $statusPanel.Anchor = 'Top,Bottom,Left,Right'
    $statusPanel.BackColor = [System.Drawing.Color]::White
    $statusPanel.BorderStyle = 'FixedSingle'
    $form.Controls.Add($statusPanel)

    $statusTitle = New-Object System.Windows.Forms.Label
    $statusTitle.Text = 'Modem status'
    $statusTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
    $statusTitle.Location = New-Object System.Drawing.Point(18, 15)
    $statusTitle.AutoSize = $true
    $statusPanel.Controls.Add($statusTitle)

    $statusHeadline = New-Object System.Windows.Forms.Label
    $statusHeadline.Name = 'StatusHeadline'
    $statusHeadline.Text = 'Detecting modem...'
    $statusHeadline.ForeColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $statusHeadline.Location = New-Object System.Drawing.Point(20, 48)
    $statusHeadline.Size = New-Object System.Drawing.Size(210, 24)
    $statusHeadline.AutoEllipsis = $true
    $statusPanel.Controls.Add($statusHeadline)

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Name = 'RefreshButton'
    $refreshButton.Text = 'Refresh'
    $refreshButton.FlatStyle = 'Flat'
    $refreshButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(209, 213, 219)
    $refreshButton.Location = New-Object System.Drawing.Point(319, 18)
    $refreshButton.Size = New-Object System.Drawing.Size(76, 32)
    $refreshButton.Anchor = 'Top,Right'
    $statusPanel.Controls.Add($refreshButton)

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Name = 'CopyButton'
    $copyButton.Text = 'Copy'
    $copyButton.FlatStyle = 'Flat'
    $copyButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(209, 213, 219)
    $copyButton.Location = New-Object System.Drawing.Point(404, 18)
    $copyButton.Size = New-Object System.Drawing.Size(76, 32)
    $copyButton.Anchor = 'Top,Right'
    $statusPanel.Controls.Add($copyButton)

    $statusBox = New-Object System.Windows.Forms.RichTextBox
    $statusBox.Name = 'StatusBox'
    $statusBox.Location = New-Object System.Drawing.Point(20, 78)
    $statusBox.Size = New-Object System.Drawing.Size(460, 376)
    $statusBox.Anchor = 'Top,Bottom,Left,Right'
    $statusBox.ReadOnly = $true
    $statusBox.DetectUrls = $false
    $statusBox.BorderStyle = 'FixedSingle'
    $statusBox.BackColor = [System.Drawing.Color]::FromArgb(249, 250, 251)
    $statusBox.Font = New-Object System.Drawing.Font('Consolas', 9.2)
    $statusPanel.Controls.Add($statusBox)

    $footer = New-Object System.Windows.Forms.Panel
    $footer.Dock = 'Bottom'
    $footer.Height = 88
    $footer.BackColor = [System.Drawing.Color]::FromArgb(244, 246, 249)
    $form.Controls.Add($footer)
    $footer.BringToFront()

    $progressLabel = New-Object System.Windows.Forms.Label
    $progressLabel.Name = 'ProgressLabel'
    $progressLabel.Text = 'Ready'
    $progressLabel.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)
    $progressLabel.Location = New-Object System.Drawing.Point(20, 12)
    $progressLabel.Size = New-Object System.Drawing.Size(690, 22)
    $progressLabel.Anchor = 'Top,Left,Right'
    $footer.Controls.Add($progressLabel)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Name = 'ProgressBar'
    $progressBar.Location = New-Object System.Drawing.Point(20, 40)
    $progressBar.Size = New-Object System.Drawing.Size(690, 8)
    $progressBar.Anchor = 'Top,Left,Right'
    $progressBar.Visible = $false
    $footer.Controls.Add($progressBar)

    $safetyLabel = New-Object System.Windows.Forms.Label
    $safetyLabel.Text = 'Do not close the window while a RAT change is in progress.'
    $safetyLabel.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
    $safetyLabel.Location = New-Object System.Drawing.Point(20, 57)
    $safetyLabel.AutoSize = $true
    $footer.Controls.Add($safetyLabel)

    $applyButton = New-Object System.Windows.Forms.Button
    $applyButton.Name = 'ApplyButton'
    $applyButton.Text = 'Apply selection'
    $applyButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
    $applyButton.ForeColor = [System.Drawing.Color]::White
    $applyButton.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $applyButton.FlatStyle = 'Flat'
    $applyButton.FlatAppearance.BorderSize = 0
    $applyButton.Location = New-Object System.Drawing.Point(742, 23)
    $applyButton.Size = New-Object System.Drawing.Size(158, 44)
    $applyButton.Anchor = 'Top,Right'
    $footer.Controls.Add($applyButton)

    $selectionTimer = New-Object System.Windows.Forms.Timer
    $selectionTimer.Interval = 80
    $selectionTimer.Tag = $form
    $selectionTimer.Add_Tick({
        param($sender, $eventArgs)
        $sender.Stop()
        $currentForm = $sender.Tag
        [uint32]$mask = Get-CheckedRatMask -List (Find-GuiControl -Form $currentForm -Name 'RatList')
        if (($mask -band [uint32]0xC0) -ne 0) {
            (Find-GuiControl -Form $currentForm -Name 'ForceCycleCheck').Checked = $true
        }
        Update-GuiSelectionSummary -Form $currentForm
    })
    $form.Tag.SelectionTimer = $selectionTimer

    $workerTimer = New-Object System.Windows.Forms.Timer
    $workerTimer.Interval = 350
    $workerTimer.Tag = $form
    $workerTimer.Add_Tick({
        param($sender, $eventArgs)
        Update-GuiWorker -Form $sender.Tag
    })
    $workerTimer.Start()
    $form.Tag.WorkerTimer = $workerTimer

    $presetCombo.Add_SelectedIndexChanged({
        param($sender, $eventArgs)
        $currentForm = $sender.FindForm()
        if ($currentForm.Tag.SuppressSelectionEvents -or $null -eq $sender.SelectedItem) {
            return
        }
        $currentForm.Tag.SuppressSelectionEvents = $true
        try {
            [uint32]$mask = $sender.SelectedItem.Mask
            Set-CheckedRatMask -List (Find-GuiControl -Form $currentForm -Name 'RatList') -Mask $mask
            (Find-GuiControl -Form $currentForm -Name 'ForceCycleCheck').Checked =
                (($mask -band [uint32]0xC0) -ne 0)
        }
        finally {
            $currentForm.Tag.SuppressSelectionEvents = $false
        }
        Update-GuiSelectionSummary -Form $currentForm
    })

    $quickPresetHandler = {
        param($sender, $eventArgs)
        $currentForm = $sender.FindForm()
        $combo = Find-GuiControl -Form $currentForm -Name 'PresetCombo'
        foreach ($preset in $combo.Items) {
            if ($preset.Id -eq [string]$sender.Tag) {
                $combo.SelectedItem = $preset
                break
            }
        }
    }
    $quickLteButton.Add_Click($quickPresetHandler)
    $quickNsaButton.Add_Click($quickPresetHandler)

    $ratList.Add_ItemCheck({
        param($sender, $eventArgs)
        $currentForm = $sender.FindForm()
        if (-not $currentForm.Tag.SuppressSelectionEvents) {
            (Find-GuiControl -Form $currentForm -Name 'PresetCombo').SelectedIndex = -1
            $currentForm.Tag.SelectionTimer.Stop()
            $currentForm.Tag.SelectionTimer.Start()
        }
    })

    $applyButton.Add_Click({
        param($sender, $eventArgs)
        try {
            Start-GuiRatWorker -Form $sender.FindForm()
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                $sender.FindForm(),
                $_.Exception.Message,
                'Unable to start RAT change',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })

    $refreshButton.Add_Click({
        param($sender, $eventArgs)
        Refresh-GuiStatus -Form $sender.FindForm()
    })

    $copyButton.Add_Click({
        param($sender, $eventArgs)
        $text = [string](Find-GuiControl -Form $sender.FindForm() -Name 'StatusBox').Text
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            [System.Windows.Forms.Clipboard]::SetText($text)
            (Find-GuiControl -Form $sender.FindForm() -Name 'ProgressLabel').Text = 'Status copied to clipboard'
        }
    })

    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($sender.Tag.Busy) {
            $eventArgs.Cancel = $true
            [void][System.Windows.Forms.MessageBox]::Show(
                $sender,
                'Wait for the current RAT change and radio recovery to finish before closing.',
                'RAT change in progress',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information)
        }
    })

    $form.Add_FormClosed({
        param($sender, $eventArgs)
        $sender.Tag.SelectionTimer.Stop()
        $sender.Tag.WorkerTimer.Stop()
        $sender.Tag.SelectionTimer.Dispose()
        $sender.Tag.WorkerTimer.Dispose()
    })

    $form.Add_Shown({
        param($sender, $eventArgs)
        Refresh-GuiStatus -Form $sender
    })

    [void]$form.ShowDialog()
}

try {
    switch ($Mode) {
        'gui' {
            Show-Gui
        }
        'status' {
            Format-StatusText (Get-RatStatus)
        }
        'lte' {
            $result = Invoke-RatChange -RequestedMask ([uint32]0x20) -RequestedLabel 'LTE only'
            'Request ID: ' + $result.RequestId + ' (' + $result.RequestedDataClass + ')'
            $result.Verification
            Format-StatusText $result.Status
        }
        'auto' {
            $result = Invoke-RatChange -RequestedMask ([uint32]0x60) -RequestedLabel 'LTE + 5G NSA' -CycleRadio
            'Request ID: ' + $result.RequestId + ' (' + $result.RequestedDataClass + ')'
            $result.Verification
            Format-StatusText $result.Status
        }
        'apply' {
            if ([string]::IsNullOrWhiteSpace($ResultPath)) {
                throw 'The background worker result path was not supplied.'
            }
            $result = Invoke-RatChange -RequestedMask $RatMask -CycleRadio:$ForceRadioCycle
            [ordered]@{
                Success = $true
                Version = $script:ToolVersion
                Result = $result
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
        }
        'diag' {
            $diagnostics = Get-DiagnosticsText
            $diagnostics
            try { Set-Clipboard -Value $diagnostics } catch { }
        }
    }
}
catch {
    if ($Mode -eq 'apply' -and -not [string]::IsNullOrWhiteSpace($ResultPath)) {
        try {
            [ordered]@{
                Success = $false
                Version = $script:ToolVersion
                Error = $_.Exception.Message
                Position = [string]$_.InvocationInfo.PositionMessage
            } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
        }
        catch { }
    }
    if ($Mode -eq 'gui') {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                'RM520N RAT Switcher error',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error)
        }
        catch { }
    }
    Write-Error $_.Exception.Message
    exit 1
}
