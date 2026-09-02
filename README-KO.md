# Windows용 Quectel RM520N RAT Switcher

Quectel RM520N WWAN 어댑터가 Windows에 보고하는 무선 접속 기술(RAT)을
선택하는 작은 Windows 도구입니다.

[English README](README.md)

## 테스트 환경

- Lenovo ThinkPad X1 Carbon Gen 13
- PCIe/MHI 방식 Quectel RM520N-GL
- Lenovo/Quectel OEM WWAN 드라이버가 설치된 Windows 11
- SK Telecom 5G NSA

표준 Windows MBN 인터페이스를 제공하는 다른 RM520N 환경에서도 동작할 수
있지만, 이 프로젝트에서 실제 하드웨어 검증한 구성은 위 환경입니다.

## 사용법

1. 릴리스 ZIP을 내려받아 새 폴더에 압축을 풉니다. ZIP 안에서 직접 실행하지
   마세요.
2. `RM520N-RAT.cmd`를 실행합니다.
3. UAC 창에서 **예**를 선택합니다.
4. 프리셋을 고르거나 모뎀이 지원하는 RAT를 개별 선택합니다.
5. **Apply selection**을 누르고 라디오 복구가 끝날 때까지 창을 닫지 마세요.

전환 중에도 창은 계속 반응하며 별도 작업 프로세스가 보내는 진행 상황을
표시합니다.

빠른 전환용 파일도 유지됩니다.

- `LTE-only.cmd`
- `5G-Auto.cmd`
- `Diagnostics.cmd`

## RAT 선택 방식

도구는 모뎀의 `SupportedDataClasses` 값을 읽고 다음 표의 표준 비트 중 실제
지원한다고 보고된 항목만 선택 목록에 넣습니다.

| 데이터 클래스 | 마스크 |
| --- | ---: |
| GPRS | `0x00000001` |
| EDGE | `0x00000002` |
| UMTS | `0x00000004` |
| HSDPA | `0x00000008` |
| HSUPA | `0x00000010` |
| LTE | `0x00000020` |
| 5G NSA | `0x00000040` |
| 5G SA | `0x00000080` |

5G NSA는 LTE 앵커가 필요하므로 UI에서 LTE도 함께 선택해야 하며 최종 요청은
`0x20 | 0x40 = 0x60`이 됩니다.

모뎀이 `Custom(0x80000000)`도 지원한다고 보고할 수 있지만, 이 비트는 제조사
전용 데이터 클래스 문자열이 필요합니다. 진단 결과에는 표시하되 잘못된 요청을
막기 위해 선택 목록에서는 제외합니다.

## 내부 동작

1. Quectel 네트워크 어댑터와 같은 GUID의 Windows MBN 인터페이스를 찾습니다.
2. 활성 셀룰러 데이터 연결을 해제합니다.
3. `IMbnRegistration::SetRegisterMode`에 자동 사업자 선택과 사용자가 고른
   데이터 클래스 마스크를 전달합니다.
4. 5G를 선택했거나 **Force network re-registration**을 켠 경우 셀룰러
   소프트웨어 라디오만 껐다 켜 새 조건으로 망에 다시 등록시킵니다.
5. 하드웨어·소프트웨어 라디오가 모두 ON인지 확인하고 실패하면 재시도합니다.
6. `CurrentDataClass`와 `AvailableDataClasses`를 폴링해 결과를 판정합니다.

이 설정은 Quectel 비공개 AT 명령으로 NVM을 변경하는 절대 RAT 잠금이 아니라
Windows와 드라이버에 전달하는 선호 데이터 클래스입니다. 요청한 기술을 사용할
수 없으면 네트워크나 드라이버가 다른 RAT로 폴백할 수 있습니다.

## 결과 해석

- **RAT change confirmed**: 현재 RAT가 선택한 데이터 클래스에 포함됩니다.
- **RAT enabled; waiting on network selection**: 요청한 5G가 현재 셀에서
  보이지만 실제 연결은 아직 다른 RAT입니다.
- **Request completed but was not confirmed**: Windows가 요청은 접수했지만
  확인 시간 안에 원하는 RAT가 보고되지 않았습니다.
- `Radio: hardware On / software On`: 라디오가 실제로 다시 켜진 상태입니다.

## 안전과 개인정보

- RAT를 바꾸는 동안 셀룰러 데이터가 잠시 끊깁니다.
- 강제 재등록은 셀룰러 소프트웨어 라디오만 잠깐 껐다 켭니다.
- 오류가 나도 라디오 ON을 재시도하고 종료 단계에서 추가 복구합니다.
- APN, 밴드, SIM 상태, 펌웨어와 Quectel NVM은 수정하지 않습니다.
- IMEI, IMSI, 전화번호와 APN 암호는 읽거나 기록하지 않습니다.
- 로그는 `%ProgramData%\RM520N-RAT\switch.log`에 시간, 요청 마스크,
  Windows 요청 ID와 결과 상태만 기록합니다.

문제가 생기면 `Diagnostics.cmd`를 실행해 전체 출력을 이슈에 첨부하세요.

## 개발 및 검사

대상 런타임은 Windows PowerShell 5.1이며 외부 PowerShell 모듈은 필요하지
않습니다.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Static.Tests.ps1
~~~

공개 배포 전에는 [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md)를 확인하세요.
재배포 권한을 결정하는 라이선스는 저장소 소유자가 직접 선택해야 하므로 임의로
추가하지 않았습니다.

## 기술 참고

- [Microsoft MBIMEx 2.0 – 5G NSA support](https://learn.microsoft.com/windows-hardware/drivers/network/mbimex-2.0-5g-nsa-support)
- [IMbnRegistration::SetRegisterMode](https://learn.microsoft.com/windows/win32/api/mbnapi/nf-mbnapi-imbnregistration-setregistermode)
- [IMbnRadio::SetSoftwareRadioState](https://learn.microsoft.com/windows/win32/api/mbnapi/nf-mbnapi-imbnradio-setsoftwareradiostate)
- [netsh mbn](https://learn.microsoft.com/windows-server/administration/windows-commands/netsh-mbn)

이 프로젝트는 Lenovo, Quectel, Microsoft 또는 SK Telecom의 공식 프로젝트가
아닙니다.
