# ADR-0011 호스팅: OCI Always Free Ampere A1 (대안: 로컬 Mac VM)

- 상태: 채택 (2026-11-11) → **대체됨 by [ADR-0014](0014-hosting-local-lima.md) (2026-11-20). OCI는 향후 이전 경로로 보존** (`TARGET=oci`, 구조만)
- 표기: 결정 **[Claude 제안]**, 0원 조건은 **[사용자 결정]** / 공통 기준은 설계 문서 §24.1
- 추가 필수 조건: **상시 공개 운영**(외부 포트 스캔 S1, 데모 URL)을 할 수 있어야 한다

## 결정
**OCI Always Free Ampere A1** VM 한 대(2 OCPU / 12 GB, arm64)에서 운영한다. PAYG로 업그레이드하지 않는다. 용량 부족이나 회수 시 **로컬 Mac VM**으로 옮긴다 (같은 매니페스트, `overlays/local`).

## 맥락
- 0원으로 K3s + OpenBao + Postgres 3개 + Relay + 앱 2개 + Ollama를 올려야 한다. 최소 8 GB 이상의 RAM이 현실적인 하한이다 (추정, §15 예산표).
- 1년 뒤에도 링크가 살아 있어야 포트폴리오로 쓸 수 있다 (기간 한정 무료는 불리).

## 비교 후보
OCI Always Free, GCP Always Free e2-micro, AWS 프리 티어, 로컬 홈랩/Mac VM

## 필수 조건 판정
| 후보 | G1 0원(상시) | 자원(8 GB 이상) | 상시 공개 운영 | 판정 |
|---|---|---|---|---|
| **OCI Always Free A1** | ○ (기간 제한 없음) | ○ 12 GB (2026-06에 24 GB에서 축소) | ○ | **통과** |
| GCP e2-micro | ○ (단, 외부 IPv4 과금 관련 보고가 있어 확인 필요) | × 1 GB | ○ | 탈락 |
| AWS 프리 티어 | × 2025-07-15 이후 신규 계정은 크레딧(최대 200달러) + 최대 6개월 무료 플랜 | 크레딧 범위에 따라 다름 | ○ | 탈락 (기간 한정) |
| 로컬 Mac VM | ○ | ○ (Mac 사양에 따라) | × (노트북이 꺼지면 중단, 공개하려면 터널 필요) | 대안으로만 |

## 비교표 (참고)
| 후보 | C2 (25%) | C3 (25%) | C4 (20%) | C5 약관/벤더 조건 (10%) | C6 (10%) | C7 (10%) | 가중 합 |
|---|---|---|---|---|---|---|---|
| **OCI A1** | 4 | 4 | 3 | 2 | 3 | 4 | **3.50** |
| 로컬 Mac VM | 4 | 3 | 4 | 5 | 2 | 4 | 3.65 — 상시 운영 조건 탈락 |
| AWS | 3 | 4 | 3 | 2 | 5 | 4 | 3.45 — 0원 조건 탈락 |
| GCP e2-micro | 1 | 3 | 3 | 3 | 4 | 4 | 2.70 — 자원 조건 탈락 |

- 로컬 Mac VM이 가중 점수는 더 높다. 하지만 "제3자가 접속해 확인할 수 있는 상시 운영"이라는 필수 조건을 못 지켜서 기본안이 될 수 없다. 이 표가 "점수보다 필수 조건이 먼저"라는 규칙을 보여주는 예다.
- C5(OCI 2점)의 이유: 유휴 회수 정책, ARM 용량 부족, 통보 없는 한도 축소(2026-06) 같은 벤더 리스크.

## OCI Always Free에서 지켜야 할 사실 (공식 문서 기준)
| 항목 | 값 |
|---|---|
| Ampere A1 | 월 1,500 OCPU-시간, 9,000 GB-시간 = **2 OCPU / 12 GB** (인스턴스 1개 2 OCPU 또는 2개 각 1 OCPU) |
| 블록 스토리지 | 부트 + 블록 볼륨 **합계 200 GB**, 볼륨 백업 5개, 홈 리전만 |
| 오브젝트 스토리지 | Always Free 전용 계정: 합계 20 GB (체험판·유료 계정은 티어별 10 GB씩) |
| 아웃바운드 | 월 10 TB |
| Load Balancer | Flexible LB 1개(10 Mbps) 무료. **이 프로젝트는 쓰지 않는다** |
| 유휴 회수 | 7일 동안 CPU(95퍼센타일), 네트워크, 메모리(A1만) 사용률이 **모두 20% 미만**이면 회수될 수 있음 |

## 왜 이것인가
1. 기간 제한 없는 0원 중 **8 GB 이상 RAM을 주는 유일한 선택지**다.
2. arm64라서 이미지를 arm64로 빌드해야 하는데, GitHub의 arm64 호스티드 러너가 공개 저장소에 무료이므로 CI 비용도 0이다.
3. 실제 공인 IP를 가진 클라우드 VM이라 외부 포트 스캔(S1), 실제 Let's Encrypt 발급, 실제 방화벽 설정을 그대로 시연할 수 있다.

## 포기한 것 (트레이드오프)
- 벤더 리스크: 회수, 용량 부족, 한도 변경. 재구축 스크립트와 백업으로 대비한다.
- 12 GB라 모델 크기와 DB 수에 제약이 있다.
- PAYG로 올리면 더 큰 한도(4 OCPU/24 GB 유지 보고)나 OKE를 쓸 수 있다는 말이 있지만, 과금 사고 위험이 있어 **업그레이드하지 않는다** (§19 비용 가드레일).

## 공개 데모와의 관계 **[사용자 결정]** U19
- 공개 데모는 회원가입을 끄고 합성 데이터와 요청자별 데모 계정만 둔다 (설계 문서 §17.1). 그래서 2 OCPU / 12 GB 노드에 불특정 다수의 가입·문의가 몰려 자원이 고갈되거나 실제 개인정보가 쌓일 위험이 낮다.
- 남는 부하는 면접관 몇 명 수준이라 Always Free 아웃바운드(월 10 TB)나 CPU 여유에 문제가 없다 (추정). 계정당 하루 LLM 작업 상한으로 2 OCPU를 보호한다.
- 매일 초기화(demo-reset CronJob)와 Ollama 상주가 CPU·메모리 사용률을 일정 수준 유지해 유휴 회수 조건(세 지표 모두 20% 미만)에 걸릴 가능성도 낮춘다. 단, 회수 판단은 Oracle 쪽이므로 재구축 대비는 그대로 둔다.

## 결정을 바꾸게 될 조건
- 계정이 회수되거나 ARM 용량을 끝내 못 얻으면: 로컬 Mac VM + 데모 시간 한정 터널로 전환 (TLS가 터널에서 종료되는 점을 README에 명시).
- Always Free 한도가 더 줄어 8 GB 미만이 되면: Ollama를 빼고 LLM 기능을 규칙 기반 분류로 낮춘다.

## 면접용 한 줄 답변
"상시 무료로 8GB 이상을 주는 곳이 OCI밖에 없었습니다. AWS는 2025년부터 신규 계정이 최대 6개월 크레딧 방식이 됐고 GCP 무료 VM은 1GB라 탈락했습니다. 대신 유휴 회수나 한도 축소 같은 벤더 리스크가 있어서 재구축 스크립트와 로컬 VM 대안을 같이 준비했습니다."

## 근거 URL
- OCI Always Free 자원(공식): https://docs.oracle.com/en-us/iaas/Content/FreeTier/resourceref.htm
- OCI A1 한도 축소 보도: https://www.infoq.com/news/2026/07/oracle-cloud-free-tier-limits/
- AWS 프리 티어 변경(2025-07): https://docs.aws.amazon.com/en_us/awsaccountbilling/latest/aboutv2/free-tier.html , https://aws.amazon.com/free/terms
- GCP 무료 등급: https://cloud.google.com/free/docs/free-cloud-features , (외부 IP 관련 2차 자료) https://yangworks.dev/guides/google-cloud-free-tier-e2-micro
- GitHub arm64 러너(공개 저장소 무료 GA): https://github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/

## 갱신 (2026-11-20): 대체됨 by ADR-0014 **[사용자 결정]** U21~U23
- 본문은 2026-11-11 판단 기록으로 그대로 둔다.
- 무엇이 바뀌었나: 사용자가 필수 조건 **"상시 공개 운영"을 "Mac이 켜져 있는 동안 공개"로 바꿨다.** 위 필수 조건 판정에서 로컬 Mac VM이 떨어진 유일한 이유가 이 조건이었으므로, 가중 점수가 더 높던 로컬 Mac VM(Lima)이 기본안이 됐다.
- 왜 바꿨나 (M1 Task 2 직전 조사, 2026-11-20 확인):
  - Oracle Always Free 문서가 A1 생성 가능 가용 도메인에서 **South Korea North(춘천)를 제외**한다. 춘천은 A1 홈 리전 후보가 아니다.
  - 서울은 가용 도메인이 하나라 "다른 AD로 재시도"를 쓸 수 없고, 무료 계정의 용량 부족 보고가 이어진다 (일화 수준, 정량 자료 없음).
  - A1 한도 절반 축소(2 OCPU / 12 GB), 유휴 회수(7일간 세 지표 모두 20% 미만), 바꿀 수 없는 홈 리전 제약은 위 본문과 같다.
  - 해외 홈 리전이나 재시도 스크립트는 결과가 보장되지 않고, 홈 리전은 한 번 고르면 바꿀 수 없다.
- 보존하는 것: 위 "OCI Always Free에서 지켜야 할 사실", 비용 가드레일 CG1~CG4·CG8(보류 상태), `k8s/overlays/oci` 자리, OCI VM 런북(future, 미검증). 이전할 때는 홈 리전·용량을 다시 조사하고, 호스트 방화벽과 Tailscale(ADR-0010)을 되살린다.
- 근거 (2026-11-20 조회): https://docs.oracle.com/iaas/Content/FreeTier/resourceref.htm (춘천 제외, 한도, 유휴 회수), https://infoq.com/news/2026/07/oracle-cloud-free-tier-limits/ (한도 축소 보도), https://wikidocs.net/blog/@insightbridge/20226/ (국내 리전 용량 관련 글, 일화)
