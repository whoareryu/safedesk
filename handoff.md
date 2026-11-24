# Handoff — 다음 세션 시작점

> 사용자가 "handoff 확인해서 작업 진행해줘"라고 하면, 이 파일을 끝까지 읽고 **"다음 세션이 할 일"** 순서대로 바로 진행한다. 다시 기획하지 않는다. 결정이 필요한 지점에서는 멈추고 사용자에게 묻는다 (아래 §3 "결정 규칙").

- 작성일: 2026-11-11, 갱신: 2026-11-24
- 현재 상태: **M1 Task 1~3 완료.** Lima VM `secure-ax`(Ubuntu 24.04 release-20260705, 2 CPU / 12 GiB / 100 GiB, 마운트·추가 네트워크 없음, 6443만 포워드)가 만들어져 있고 하드닝(`bootstrap.sh`)이 적용됨. 노출 검사(`m1-exposure.sh --stage base`)와 LAN 스캔(Docker, VM 꺼짐/켜짐 비교) PASS, 증거는 `docs/evidence/m1/`. M1 실행 기준은 `docs/superpowers/plans/2026-11-20-m1-local-cloudflare.md`. 진행 원장은 `.superpowers/sdd/2026-11-20-m1-local-cloudflare/progress.md`(USER 줄 = 사용자 결정, M1 최종 리뷰로 미룬 사소 항목 포함). 다음 작업은 **M1 Task 4 (K3s 설치, API는 Mac `127.0.0.1:6443`만)**.
- 이 Mac 환경 결정(2026-11-24): Colima 정지(외부 노출 `*:10250`, `*:53`), macOS 원격 로그인 끔(22가 LAN에 열려 있었음). LAN 스캔 전에는 Colima를 다시 꺼야 한다. `config/cluster.env`에 `TARGET=local`, `LIMA_INSTANCE=secure-ax`, `TUNNEL_NAME=safedesk-demo`, `K3S_VERSION=v1.36.6+k3s1`, ACME 이메일이 들어 있다(gitignore).

## 1. 프로젝트 한 줄 요약

AI 고객문의 서비스(SafeDesk)와 가벼운 데모 앱(MiniShop)이 같은 **PII Relay**를 끼워 쓰는 구조를 K3s 위에서 운영하는 보안 포트폴리오다. 런타임은 MacBook의 Lima VM이고, 보여줄 때만 켜서 Cloudflare 터널로 공개한다. 비용은 **기존 개인 도메인을 쓰고 프로젝트가 추가로 내는 비용 0원**이다. 목표는 "고객도, 프로젝트 주인도 개인정보를 함부로 볼 수 없고, 보면 반드시 흔적이 남는다"를 공격 시연으로 증명하는 것.

## 2. 꼭 읽을 파일

| 파일 | 용도 |
|---|---|
| `docs/2026-11-11-secure-ax-k3s-design.md` | 기획서 (**v5**, 2026-11-20). §4 사용자 결정 U1~U35. 로컬·Cloudflare 기준은 §3, §11.4, §17.1, §19 |
| `docs/adr/0001~0015` | 기술 선정 근거 (면접 대비). 이번 변경: 0014(로컬 Lima 호스팅), 0015(Cloudflare 터널·에지), 0003(DNS-01로 갱신), 0010(로컬 보류), 0011(대체됨, OCI는 향후 이전 경로), 0002·0008(보완) |
| `docs/superpowers/plans/2026-11-20-m1-local-cloudflare.md` | **M1 실행 기준 (Task 2~12, 완료 기준 C1~C19)** |
| `docs/superpowers/plans/2026-11-11-m1-infra-foundation.md` | 기존 M1 계획. Task 1은 이 문서 기준으로 끝났다. Task 2 이후는 개정 계획이 대체 |
| `.superpowers/sdd/2026-11-11-m1-infra-foundation/progress.md` | 진행 원장. 사용자 결정(USER 줄)과 Task별 리뷰 이력 |

## 3. 확정된 진행 방식

- **실행 방식 (사용자 확정, 2026-11-20):** 서브에이전트 병렬 실행. **결정 규칙:** 모든 결정은 사용자가 내린다. 결정이 필요하면 선택지와 **추천안(이유 포함)**을 함께 묻고, 답을 받기 전에는 정하지 않는다. 독립적인 작업은 **서브에이전트를 병렬로** 돌린다 (`superpowers:subagent-driven-development`). 진행과 결정은 위 진행 원장에 기록한다.
- **절차:** 각 Task는 "검증 스크립트 먼저 → 실패 확인 → 구현/적용 → 통과 확인 → 리뷰 → 커밋" 순서로 진행한다.
- **저장소:** `github.com/whoareryu/safedesk` (public). Secret scanning과 push protection이 켜져 있다. 커밋 작성자 이메일은 저장소 로컬 설정의 GitHub noreply 주소를 쓴다 (전역 설정을 바꾸지 않는다). 커밋 메시지에 `Co-Authored-By` 트레일러를 넣지 않는다.
- **사용자가 직접 해야 하는 단계:** 그 단계에 오면 할 일을 짧게 안내하고, 결과(출력이나 캡처, 비밀값은 가린 것)를 받아서 이어간다.
  - Lima: VM 생성·시작 확인(`limactl create/start`), VM stop/start와 Mac 잠자기 후 재검증
  - S1 보강: **같은 LAN의 다른 실제 기기**(다른 노트북, 또는 Termux에서 nmap을 돌리는 휴대폰)에서 Mac LAN IP를 `nmap -n -oG`로 스캔. 검증 스크립트가 `-oG` 출력을 읽으므로 nmap이 아닌 스캔 앱은 쓰지 않는다 (U35). 같은 Mac의 Docker 컨테이너는 대체 수단이며, 쓰면 Docker VM 네트워크를 거쳤을 수 있다는 한계를 증거에 적는다 (U33, U34)
  - LAN 스캔 대조 포트 18090: macOS 애플리케이션 방화벽이 막으면 스캔하는 동안만 python을 허용하고 끝나면 제거, 포트와 허용 사실을 증거에 기록 (U35). nmap은 `-n`으로 돌리고 호스트 이름·MAC 주소는 가린다 (가림 규칙은 사용자 결정 U35)
  - 시연: `make demo-up`(VM 시작, `caffeinate`, 시계 차이 확인)으로 켜고, `make demo-down`은 `caffeinate`를 해제하고 VM을 정지한다(`limactl stop`). 두 타깃은 **M1 Task 12**에서 만든다. 평소 꺼져 있으면 방문자는 Cloudflare 기본 오류 화면을 본다 (U33~U35)
  - Cloudflare 대시보드 — 계정·비용: Billing에서 **유료 구독 0개**와 결제수단 상태 확인, 결제수단이 있으면 제거 시도(안 되면 이유와 "구독 0개" 화면 기록), zone 플랜 Free 확인, 금지 유료 기능 목록 점검 (기획서 §19.2 CG-CF1~CG-CF4). 캡처는 이메일·계정 ID·카드 끝자리를 가려서 `docs/cost/`에. **모든 Cloudflare 대시보드 캡처**에서 계정 이메일·계정 이름·ID를 가린다
  - Cloudflare 대시보드 — DNS 기준선: apex와 `www`의 레코드·프록시 상태 캡처 (DNS-only, 건드리지 않음)
  - Cloudflare 대시보드 — API 토큰: DNS-01용 토큰(이 zone 하나, Zone·DNS·Edit + Zone·Zone·Read(cert-manager에 기술적으로 필요, 사용자 승인), 집 공인 **IPv4** 필터, 6개월 만료)을 만들어 **화면에서 바로 Mac 키체인에 저장**. 설정 내보내기용 읽기 전용 토큰도 같은 제한(단일 zone, 집 IPv4 필터, 6개월 만료)으로 같은 방식 (U25, U35)
  - 터널: `cloudflared tunnel login`(브라우저), `tunnel create`, `tunnel route dns` 세 호스트. 끝나면 `cert.pem` 삭제. Zero Trust 온보딩이 결제수단을 요구하면 진행하지 않고 CLI 경로로 돌아온다
  - Cloudflare 대시보드 — 에지 규칙: Bot Fight Mode, Free Managed Ruleset, rate limit 1개, WAF 커스텀 R1~R4, 캐시 우회, SSL Full (strict)·Always Use HTTPS·최소 TLS 1.2 (기획서 §11.4). 화면 캡처
  - 월 1회 비용 점검 (Cloudflare Billing, GitHub 사용량)
- **지켜야 할 원칙:**
  - 프로젝트 추가 비용 0원 (기획서 §19.2. OCI용 CG1~CG4·CG8은 보류, CG-CF1~CG-CF4 적용)
  - 비밀값 커밋 금지 (저장소 public). Cloudflare 토큰, 터널 자격 증명 JSON·`cert.pem`, 터널 UUID, ACME 이메일, kubeconfig는 저장소에 넣지 않는다
  - apex/`www`(Vercel)의 DNS 레코드·프록시 상태를 바꾸지 않는다. Cloudflare 규칙은 세 호스트로 범위를 좁힌다
  - 공개 데모는 합성 데이터만 (Cloudflare 에지가 평문을 볼 수 있음)
  - 스크립트는 bash 3.2 호환
  - 기술을 선택할 때마다 선정 근거와 비교 대안을 남긴다

## 4. 다음 세션이 할 일 — M1 Task 4: K3s 설치

**기준은 계획 문서의 "Task 4"다.** 브리프는 `superpowers:subagent-driven-development`의 `scripts/task-brief <plan> 4`로 뽑는다.

- 시작 전 확인: `limactl list`에서 `secure-ax`가 Running인지, `vm_run --root scripts/verify/m1-hardening.sh` PASS(부팅 직후엔 NTP 동기화를 몇 초 기다린다).
- K3s 버전은 `v1.36.6+k3s1`(사용자 결정, `config/cluster.env`). 설치 스크립트 sha256 기록, `--secrets-encryption`, kubeconfig는 Mac `127.0.0.1:6443`만.
- 끝나면 `m1-exposure.sh --stage k3s` PASS (Mac 리스너에 `127.0.0.1:6443` 추가).
- 도구: `vm_run [--root]`(scripts/lib, scripts/verify/lib, scripts/host 최상위 파일을 VM /tmp로 복사해 실행), 증거는 저장 전 `scrub_evidence` → `check-evidence-clean`.

## 5. Task 4 다음

- Task 5 주의: `check-evidence-clean`이 공개 IP도 잡는다. Cloudflare·Vercel IP가 든 증거는 먼저 `config/evidence-public-ips.txt`에 /16 이하 대역이나 정확한 주소로 넣는다(사설 대역과 겹치거나 /16보다 넓으면 거부됨).
- 개정 계획 순서: Task 5 Cloudflare 계정·비용 점검, DNS 기준선, DNS-01 토큰, cert-manager → Task 6 Traefik → Task 7 네임스페이스·PSA·default-deny(N5 없음) → Task 8 더미 앱·인증서 staging→prod → Task 9 cloudflared 터널 → Task 10 에지 통제 → Task 11 netmatrix → Task 12 통합 검증·VM 생명주기·`make demo-up`/`demo-down`.
- **작업 끝날 때:** 이 `handoff.md`의 "현재 상태"와 "다음 세션이 할 일"을 다음 Task 기준으로 갱신하고, 진행 원장에도 기록한다.

## 6. 기억해 둘 사실 (조사로 확인됨)

- OCI Always Free A1: 2 OCPU / 12 GB로 축소. Always Free 문서가 A1 생성 가능 AD에서 **춘천을 제외**, 서울은 단일 AD. 그래서 당분간 OCI를 쓰지 않는다 (향후 이전 경로로만 보존, ADR-0011·0014). PAYG 업그레이드는 금지.
- Cloudflare Free 한도 (2026-11-20 조회): rate limiting 규칙 1개(10초 고정), WAF 커스텀 규칙 5개, 관리형 규칙은 Free Managed Ruleset만, Bot Fight Mode는 WAF로 예외 불가, Universal SSL은 1단계 서브도메인까지, 6443은 프록시 포트가 아님.
- cloudflared 이그레스는 7844(TCP http2 / UDP QUIC) 필수, 443은 선택. TLS 검증 기본 켜짐, `originServerName`으로 호스트별 검증.
- Lima 게스트 에이전트는 guest 리스너(K8s LoadBalancer/NodePort 포함)를 Mac `127.0.0.1`로 자동 포워드한다. catch-all `ignore`가 필수. 기본 템플릿은 홈을 읽기 전용 마운트하므로 `mounts: []`를 명시한다.
- apex/`www`는 DNS-only로 Vercel을 가리킨다. Let's Encrypt 주간 한도를 같은 등록 도메인으로 공유할 수 있으니 prod 재발급을 반복하지 않는다.
- ingress-nginx: 2026-03 EOL. Traefik을 선택한 근거 중 하나.
- trivy-action 태그 탈취 사고(2026-03, CVE-2026-33634): GitHub Action은 커밋 SHA로 고정한다.
- Gemini 무료 티어는 입력 데이터가 Google 제품 개선에 쓰일 수 있어 사용하지 않는다. LLM은 Ollama 전용.
