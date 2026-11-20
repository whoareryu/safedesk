# ADR-0014 호스팅: MacBook 위 로컬 Lima VM (OCI는 향후 이전 경로)

- 상태: 채택 (2026-11-20). ADR-0011을 대체한다 (OCI는 향후 이전 경로로 보존)
- 표기: 결정 **[사용자 결정]** U21~U23, U30 / 세부 구성 **[Claude 제안]** / 공통 기준은 설계 문서 §24.1
- 바뀐 필수 조건 **[사용자 결정]**: ADR-0011의 "상시 공개 운영"을 **"Mac이 켜져 있는 동안 공개"**로 바꾼다. 포트폴리오는 보여줄 때만 켜면 된다

## 결정
런타임은 사용자의 **MacBook(Apple Silicon) 위 Lima VM** 한 대다.

- Ubuntu 24.04 arm64(`template:ubuntu-24.04` 기반), `vmType: vz`, **2 CPU / 12 GiB / 디스크 100 GiB** (OCI Always Free A1 한도와 같게 맞춰 설계 문서 §15.1 예산을 그대로 쓴다)
- Mac 홈 디렉터리를 마운트하지 않는다 (`mounts: []`)
- Lima 포트 포워드는 guest 6443 → Mac `127.0.0.1:6443` 하나만 두고, 나머지는 catch-all `ignore`로 막는다
- 관리 접속은 `limactl shell`과 Mac `127.0.0.1:6443`. Tailscale은 로컬에서 쓰지 않는다 (ADR-0010 보류)
- 로컬에서는 호스트 방화벽을 두지 않고, OCI로 옮길 때 도입한다
- 확장성은 **구조만**: `TARGET=local|oci`. `TARGET=oci`는 "not implemented"로 거부하고, `k8s/overlays/oci`와 OCI 런북은 자리만 둔다. 검증되지 않은 OCI 전용 코드는 만들지 않는다
- 공개 접근은 ADR-0015(Cloudflare 이름 있는 터널)

## 맥락
- 2026-11-11에는 OCI Always Free A1을 기본안으로 골랐다 (ADR-0011). M1 Task 2(홈 리전 선택) 직전에 용량 회피 방법을 조사하면서 다음을 확인했다 (2026-11-20).
  - Oracle Always Free 문서는 A1을 "South Korea North(춘천)를 **제외한**" 가용 도메인에서 만들 수 있다고 적는다. 춘천은 A1 홈 리전 후보가 될 수 없다.
  - 서울(ap-seoul-1)은 가용 도메인이 하나라 "다른 AD로 재시도"를 쓸 수 없다. 무료 계정의 서울 "Out of host capacity" 보고가 2022년부터 이어지지만, 정량 자료는 없다 (일화 수준).
  - A1 한도는 2 OCPU / 12 GB로 절반이 됐다 (시행일은 자료마다 다름). 7일 동안 CPU·네트워크·메모리가 모두 20% 미만이면 회수될 수 있다. Always Free 자원은 바꿀 수 없는 홈 리전에만 만들 수 있다.
  - 상시 무료로 8 GB 이상을 주는 다른 VM은 찾지 못했다 (GCP e2-micro 1 GB 등).
- 해외 리전(도쿄, 오사카, 싱가포르 등)을 고르면 용량이 나을 수 있다는 보고도 일화뿐이고, 홈 리전은 한 번 고르면 바꿀 수 없다. 재시도 스크립트로 며칠~몇 주를 기다리는 방법도 보고되지만 결과가 보장되지 않는다.
- 사용자는 이 상황에서 "당분간 OCI를 쓰지 않고, 보여줄 때만 Mac에서 켠다. 나중에 OCI나 실제 배포로 옮길 수 있게 구조만 남긴다"를 골랐다.

## 비교 후보
1. 실행 장소: 로컬 Mac VM, OCI A1(서울 재시도 / 해외 홈 리전), 다른 클라우드 무료 VM
2. 로컬 VM 도구: Lima, colima, Multipass, OrbStack

## 필수 조건 판정 (실행 장소, 바뀐 조건 기준)
| 후보 | G1 0원(상시) | 자원 8 GB 이상 | 지금 바로 확보 가능 | 판정 |
|---|---|---|---|---|
| **로컬 Mac VM** | ○ (기존 장비) | ○ 12 GiB | ○ | **통과** |
| OCI A1 (서울) | ○ | ○ 12 GB | × 단일 AD, 용량 부족 보고, 확보 시점 불명 | 보류 (향후 이전 경로) |
| OCI A1 (해외 홈 리전) | ○ | ○ 12 GB | △ 용량 일화뿐, 홈 리전 변경 불가 | 보류 |
| GCP e2-micro 등 | ○ | × 1 GB | ○ | 탈락 |

- 2026-11-11 ADR-0011 표에서 로컬 Mac VM은 가중 점수가 더 높았지만(3.65 대 3.50) "상시 공개 운영" 필수 조건 때문에 탈락했다. 이번에는 사용자가 필수 조건을 바꿨으므로 그 표의 판단이 그대로 뒤집힌다. 점수를 다시 매기지 않았다.

## 로컬 VM 도구 비교 **[Claude 제안]**
| 도구 | 장점 | 이 프로젝트에서의 약점 |
|---|---|---|
| **Lima** | 오픈소스(CNCF), Apple Virtualization(vz) 지원, Ubuntu 템플릿, YAML 하나로 CPU·메모리·디스크·**마운트·포트 포워드를 선언**하고 저장소에 커밋할 수 있음. 자동 포워드를 catch-all `ignore`로 끌 수 있음 | 게스트 에이전트의 자동 포트 포워드가 기본으로 켜져 있어 규칙을 빠뜨리면 노출이 생김 (M1에서 음성 검사). 기본 템플릿은 홈을 읽기 전용 마운트하므로 `mounts: []`를 명시해야 함 |
| colima | Lima 위에 만든 컨테이너 런타임용 래퍼 | 목적이 Docker/containerd 실행이라 VM 경계 설정을 Lima보다 간접적으로 다룸. 이 프로젝트는 K3s를 VM에 직접 설치하므로 Lima를 바로 쓰는 편이 단순함 |
| Multipass | Canonical 제작, Ubuntu VM 생성이 간단함 | 포트 포워드·마운트를 선언형 파일로 저장소에 남기는 방식이 Lima보다 약함 (추정, 2026-11 미확인) |
| OrbStack | 빠르고 편함 | 독점 소프트웨어이고 개인 무료/상업 유료 라이선스 조건이 있음 (2026-11 미확인). VM 경계를 코드로 감사하기 어려움 (추정) |

## 왜 이것인가
1. **지금 바로 확보할 수 있는** 유일한 12 GB급 0원 실행 환경이다. 같은 arm64라 이미지를 그대로 쓴다.
2. 자원을 OCI A1과 같게 맞춰서, 나중에 옮겨도 §15.1 예산과 매니페스트가 그대로 유효하다.
3. Lima는 VM 경계(마운트 없음, 포워드 6443만)를 YAML로 선언하고 저장소에 남길 수 있어 "노출 0"을 검증 스크립트로 증명하기 좋다.
4. 공개 경로를 터널로 바꾸면 인바운드 포트가 아예 없어져, 클라우드 VM보다 공격 표면이 작다 (ADR-0015).

## 포기한 것 (트레이드오프)
- **가용성**: Mac이 꺼지거나 잠들면 서비스가 멈춘다. 면접관이 아무 때나 접속하면 Cloudflare 기본 오류 화면을 본다. **[사용자 결정]** U33: 사용자 지정 오류 페이지는 두지 않고 README에 "시연은 요청 시 Mac을 켜서 공개합니다. 평소에는 Cloudflare 기본 오류 페이지가 나오며, 영상·캡처를 참고해 주세요."라고 쓴다. 시연 중 잠자기는 `make demo-up`의 `caffeinate`로 막고 시계 차이를 확인한다 (`make demo-down`은 `caffeinate`를 해제하고 VM을 정지한다(`limactl stop`), M1 Task 12에서 구현, U34·U35).
- **외부 포트 스캔 시연(S1 원형)**: 공인 IP가 없어 "nmap에 80/443만"을 보여줄 수 없다. 대신 리스너·포워드·터널 설정 감사·공개 호스트 음성 검사, 그리고 같은 LAN의 다른 실제 기기에서 Mac LAN IP를 nmap으로 스캔해 "인바운드 0"을 보인다 (U33, U34. 같은 Mac의 Docker 컨테이너는 대체 수단이며 한계를 증거에 적는다) (설계 문서 §17 S1).
- **실제 클라우드 방화벽 설정 시연**: OCI Security List·호스트 방화벽 시연이 빠진다. 로컬 호스트 방화벽도 생략했으므로 다층 방어 한 겹이 비어 있다 (설계 문서 §22).
- **노드 = 운영자의 일상용 노트북**: Mac이 침해되면 VM도 침해된 것으로 본다.
- CPU 성능이 OCI A1과 달라 Ollama 처리 시간 같은 수치는 로컬 실측값으로만 쓸 수 있다.

## 결과 (Consequences)
- 설계 문서 §3, §15, §19.1이 로컬 기준으로 바뀌고, OCI 내용은 §19.1.1 "향후 이전 경로"로 옮겼다. 비용 가드레일 CG1~CG4, CG8은 보류.
- M1 계획(`docs/superpowers/plans/2026-11-20-m1-local-cloudflare.md`)은 Task 2를 Lima VM 정의와 Mac 쪽 노출 검증으로 바꾼다. `config/cluster.env`에 `TARGET`, `LIMA_INSTANCE`가 들어가고 `PUBLIC_IP`, `TS_IP`는 빠진다 (Task 2 Step 0).
- M1 완료 기준에 VM stop/start와 Mac 잠자기 후 재검증, 시계 동기화 확인이 추가된다.
- `audit-anchor`의 외부 대상이었던 OCI Object Storage를 쓸 수 없으므로 M4에서 다시 정한다 (U31).

## 결정을 바꾸게 될 조건
- 상시 공개가 다시 필요해지면(예: 면접 일정이 많아짐): OCI A1(홈 리전 재조사) 또는 다른 저비용 호스팅으로 `TARGET=oci`를 구현한다. 그때 호스트 방화벽, Tailscale(ADR-0010), OCI 비용 가드레일을 되살린다.
- Mac 메모리가 부족해 다른 작업과 충돌하면: VM 메모리를 줄이고 §15.1의 "줄이는 순서"를 적용한다.

## 면접용 한 줄 답변
"무료로 12GB급을 주는 곳이 OCI ARM뿐이었는데, 춘천 리전은 무료 ARM 대상에서 빠져 있고 서울은 가용 도메인이 하나라 용량 확보가 보장되지 않았습니다. 그래서 같은 2코어 12GB 크기의 Lima VM을 Mac에 두고 보여줄 때만 켜기로 했고, 클라우드로 옮길 수 있게 TARGET 구조는 남겨 뒀습니다."

## 근거 URL (2026-11-20 조회)
- OCI Always Free 자원(공식, A1 한도·춘천 제외·유휴 회수): https://docs.oracle.com/iaas/Content/FreeTier/resourceref.htm
- OCI A1 한도 축소 보도 (2026-07-03): https://infoq.com/news/2026/07/oracle-cloud-free-tier-limits/
- 서울·춘천 무료 용량 관련 국내 글 (일화, 2026): https://wikidocs.net/blog/@insightbridge/20226/
- 용량 부족 재시도 경험담 (2026-06-07, 07-19 수정): https://dev.to/alexpua/how-i-stopped-fighting-oracles-out-of-host-capacity-and-let-a-script-catch-a-free-arm-server-for-41a6
- 커뮤니티 보고 요약 (2026-02-15): https://ekadetov.github.io/2026/02/15/blog-post-hackernews.html
- Lima 템플릿: https://lima-vm.io/docs/templates/
- Lima 포트 포워드 (자동 포워드, `ignore`, `guestIPMustBeZero`): https://lima-vm.io/docs/config/port/
- Lima 기본 템플릿 (홈 마운트, vz 기본): https://raw.githubusercontent.com/lima-vm/lima/master/templates/default.yaml
