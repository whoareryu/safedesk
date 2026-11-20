# ADR-0015 공개 접근과 에지 보안: Cloudflare 이름 있는 터널 + Cloudflare Free 에지 통제

- 상태: 채택 (2026-11-20)
- 표기: 결정 **[사용자 결정]** U24~U29 / 세부 구성 **[Claude 제안]** / 공통 기준은 설계 문서 §24.1
- 추가 필수 조건: 인바운드 포트를 하나도 열지 않는다. 프로젝트 추가 비용 0원. 공개 링크는 개인 도메인 아래 고정 이름이어야 한다

## 결정
- 로컬 Lima VM(ADR-0014)의 서비스를 **Cloudflare 이름 있는 터널**로 공개한다.
  - cloudflared는 **VM 호스트의 systemd 서비스**로 돌린다 (클러스터 밖). 그래서 "클러스터 안의 상시 외부 egress는 `audit-anchor`뿐"(설계 문서 §10) 원칙이 유지된다.
  - 호스트는 `safedesk.whoareryu.cloud`, `minishop.whoareryu.cloud`, `relay.whoareryu.cloud`. zone은 이미 Cloudflare 네임서버에 있고, apex와 `www`(Vercel, DNS-only)는 건드리지 않는다.
  - 터널은 CLI로 만들고 ingress 설정은 저장소의 `config.yml` 템플릿으로 관리한다. ingress는 세 호스트 → `https://<노드 IP>:443`(Traefik)과 catch-all `http_status:404`뿐이다. 호스트마다 `originServerName`으로 원본 인증서를 검증하고 `noTLSVerify`는 금지한다.
  - 계정 인증서 `cert.pem`은 터널 생성·DNS 라우팅 직후 Mac에서 지운다. 터널 자격 증명 JSON은 VM `/etc/cloudflared/`에만 두고 백업하지 않는다 (분실하면 터널을 다시 만든다).
- 원본 구간은 cert-manager + Let's Encrypt **DNS-01** 인증서로 TLS를 유지하고, 에지 SSL 모드는 Full (strict)이다 (ADR-0003 갱신).
- 공개 링크는 **Mac이 켜져 있는 동안 누구나** 쓸 수 있다 (Cloudflare Access 로그인 없음). 대신 Cloudflare Free의 통제를 모두 켠다: Bot Fight Mode, Free Managed Ruleset, rate limiting 규칙 1개(로그인·동의·콘솔 경로, IP당 10초에 5회 초과 → 10초 차단), WAF 커스텀 규칙(R1 KR 외 국가 차단, R2 relay `/console` Managed Challenge, R3 `/signup` 차단, R4 메서드 GET/POST/HEAD만, R5 예비), 세 호스트 캐시 우회. relay `/console`은 IP allowlist 없이 Managed Challenge + rate limit + 상담원 TOTP로 보호한다 (U33). 모든 규칙은 세 호스트로 범위를 좁혀 apex/www에 걸리지 않게 한다 (설계 문서 §11.4).
- 설정은 대시보드에서 하고, 읽기 전용 API 토큰으로 규칙·설정 JSON을 내보내 증거로 남긴다. 이 토큰도 DNS-01 토큰과 같은 제한(단일 zone, 집 공인 IPv4 필터, 6개월 만료, 원본은 Mac 키체인)을 둔다. ID·UUID·이메일을 뺀 정규화 JSON은 공개 저장소에 커밋해 드리프트 기준선으로 쓰고 pre-commit 검사로 지킨다. Cloudflare API 호출은 IPv4로 강제한다(`curl -4`) (U35).
- 비용: Free 플랜만, 결제수단 확인·제거 안내, 금지 유료 기능 목록, 월간 청구 화면 점검 (설계 문서 §19.2 CG-CF1~CG-CF4).

## 맥락
- 로컬 VM에는 공인 IP가 없고, 가정용 회선은 CGNAT일 수 있다. 공유기 포트를 열면 집 IP가 드러나고 인바운드 포트가 생긴다.
- 사용자는 이미 `whoareryu.cloud`를 갖고 있고 네임서버가 Cloudflare에 있다 (apex/www는 Vercel). 그래서 2026-11-11 ADR-0003·0010에서 Cloudflare를 떨어뜨린 이유("DuckDNS라 네임서버를 옮길 수 없음")가 사라졌다.
- 공개 데모의 위험은 세 가지다: 위험한 외부 접근, 비용 발생, 개인정보 수집·유출. 사용자는 로그인 게이트 대신 이 세 경로를 강하게 막는 쪽을 골랐다.

## 비교 후보
1. 공개 방식: Cloudflare 이름 있는 터널, Cloudflare quick tunnel, Tailscale Funnel, 공유기 포트 포워딩
2. cloudflared 위치: VM 호스트 systemd, 클러스터 안 Deployment
3. 접근 범위: 누구나(에지 통제), Cloudflare Access 로그인 게이트

## 비교표 (공개 방식)
| 후보 | 인바운드 포트 0 | 개인 도메인 고정 이름 | 0원 | 무료 에지 통제 | 판정 |
|---|---|---|---|---|---|
| **Cloudflare 이름 있는 터널** | ○ (아웃바운드 7844) | ○ | ○ | ○ WAF·봇·rate limit | **채택** |
| Cloudflare quick tunnel | ○ | × `trycloudflare.com` 임의 이름, 재시작마다 바뀜 | ○ | × | 탈락 |
| Tailscale Funnel | ○ | × `*.ts.net` 이름, 포트 443/8443/10000만 (2026-11 약관 미확인) | ○ | × | 탈락 |
| 공유기 포트 포워딩 | × 443 공개, 집 IP 노출, CGNAT면 불가 | ○ (DNS 직접) | ○ | × | 탈락 (필수 조건) |

## cloudflared 위치
| 후보 | 장점 | 단점 |
|---|---|---|
| **VM 호스트 systemd** | 클러스터 안 외부 egress 예외가 늘지 않음. Pod가 터널 자격 증명에 닿지 않음. systemd 하드닝 가능 | 호스트 수준 설치·검증 스크립트가 필요하고, NetworkPolicy로 통제할 수 없음 |
| 클러스터 안 Deployment | 매니페스트로 관리, 재시작 자동 | 상시 외부 egress(7844)를 가진 Pod가 생겨 §10 원칙과 충돌. 자격 증명이 K8s Secret으로 클러스터 안에 들어옴 |

## 원본 TLS
| 후보 | 판정 |
|---|---|
| **LE DNS-01 인증서 + Full (strict) + cloudflared 원본 검증** | 채택. 원본 구간도 공인 인증서로 검증되고 cert-manager 시연이 유지됨. 솔버 Pod가 없음 |
| Cloudflare Origin CA 인증서 | Cloudflare만 신뢰하는 인증서라 원본 구간 시연 가치가 낮음 |
| 터널 → Traefik 평문 HTTP | "클러스터 안이라고 평문으로 두지 않는다" 원칙과 충돌 |

## 왜 이것인가
1. 인바운드 포트 0으로 개인 도메인 아래 고정 링크를 0원에 만들 수 있는 유일한 후보다.
2. Free 플랜에서도 WAF 커스텀 규칙 5개, rate limit 1개, Free Managed Ruleset, Bot Fight Mode를 쓸 수 있어 "누구나 접속" 조건의 남용을 에지에서 줄인다. 2026-11-11 ADR-0002의 "앞단 WAF" 조건이 이것으로 실현된다.
3. cloudflared를 호스트에 두면 클러스터 egress 원칙과 Pod 권한 경계가 바뀌지 않는다.

## 포기한 것 (트레이드오프)
- **Cloudflare가 평문을 볼 수 있다.** 에지에서 방문자 TLS를 종료하기 때문이다. 그래서 공개 데모는 **합성 데이터만** 쓰고, 가입을 끄고, 실제 개인정보 입력 금지 경고·길이 제한·약 1시간 물리 삭제를 둔다 (설계 문서 §17.1, §22). "운영자도 못 본다"는 주장은 클러스터 안 데이터 경로에 대한 것이다.
- 에지가 `server: cloudflare` 헤더를 붙이는 것은 막을 수 없다. S11 기준을 "원본 정보 미노출"로 바꿨다.
- 국가 차단은 IP 지리 정보 기반이라 VPN으로 우회된다. KR 안에서는 행동 검증을 못 해 대시보드 증거와 GitHub Actions 미국 러너 관측에 기댄다.
- Bot Fight Mode는 WAF로 예외를 줄 수 없어 자동 검증 요청이 챌린지를 받을 수 있다. JS 탐지는 엄격한 CSP와 맞지 않을 수 있어 영향을 기록하고 M3에서 nonce를 다시 본다.
- DNS-01 토큰은 zone 레코드를 고칠 수 있어 apex/www까지 영향을 줄 수 있다. 단일 zone, 집 IP 필터, 6개월 만료, Mac 키체인 원본으로 줄인다.
- 터널 자격 증명이 새면 공격자가 같은 터널로 커넥터를 띄워 트래픽 일부를 가로챌 수 있다. VM에만 두고 백업하지 않는다.
- Cloudflare 무료 조건에 의존한다 (벤더 리스크).

## 결과 (Consequences)
- 설계 문서 §5.2 구성도에 Cloudflare 에지와 VM 호스트 cloudflared가 들어가고, §11에 에지 설정 표(§11.4)가 생긴다.
- §10 N5(HTTP-01 솔버 허용)는 폐지되고, netmatrix에 M1-X9~X11(cloudflared metrics, Cloudflare API, 터널 엔드포인트 차단)이 추가된다.
- S1은 공인 IP nmap 대신 리스너·포워드·터널 설정 감사·공개 호스트 음성 검사 + Mac LAN IP nmap(같은 LAN의 다른 실제 기기가 기본, 같은 Mac의 Docker 컨테이너는 한계를 적은 대체 수단, U34)으로, S11은 에지와 원본을 따로, S12는 429 출처(에지/Traefik)를 구분해 기록한다.
- 비용 가드레일에 CG-CF1~CG-CF4가 생기고 CG7·CG10이 바뀐다.
- M1 완료 기준에 에지 통제 동작, apex/www 불변, Cloudflare 비용 증거가 들어간다.

## 결정을 바꾸게 될 조건
- 실제 개인정보를 다루는 서비스가 되면: 에지 TLS 종료를 받아들일지 다시 정한다 (예: Cloudflare 앞단 없이 원본에서 직접 TLS, 또는 계약상 처리 위탁 구조).
- 남용이 실제로 생기면: Cloudflare Access 게이트(이메일 OTP 등)를 추가로 검토한다.
- Cloudflare Free 조건이 바뀌어 비용이 생기면: Tailscale Funnel 등으로 공개 방식을 다시 고른다.
- `TARGET=oci`로 옮기면: 공인 IP + Traefik 80/443 직접 공개와 이 터널 구성 중 무엇을 쓸지 그때 정한다.

## 면접용 한 줄 답변
"노트북 VM에 공인 IP가 없어서 VM이 먼저 Cloudflare로 연결을 여는 이름 있는 터널을 썼고, 그래서 밖에서 들어오는 포트가 하나도 없습니다. 누구나 들어올 수 있게 열어 둔 대신 무료 WAF·봇 차단·rate limit·국가 차단을 켰고, Cloudflare가 에지에서 평문을 볼 수 있다는 한계 때문에 공개 데모는 합성 데이터만 씁니다."

## 근거 URL (2026-11-20 조회)
- Rate limiting 규칙 (Free 1개, 10초): https://developers.cloudflare.com/waf/rate-limiting-rules/ , https://developers.cloudflare.com/waf/rate-limiting-rules/parameters/
- WAF 커스텀 규칙 (Free 5개): https://developers.cloudflare.com/waf/custom-rules/
- `ip.src.country` 필드: https://developers.cloudflare.com/ruleset-engine/rules-language/fields/reference/ip.src.country/
- 관리형 규칙 (Free Managed Ruleset): https://developers.cloudflare.com/waf/managed-rules/
- Bot Fight Mode: https://developers.cloudflare.com/bots/get-started/bot-fight-mode/ , https://developers.cloudflare.com/bots/plans/free
- Universal SSL 한계 (1단계 서브도메인): https://developers.cloudflare.com/ssl/edge-certificates/universal-ssl/limitations/
- 프록시 포트 (6443 미포함): https://developers.cloudflare.com/fundamentals/reference/network-ports/
- 터널 방화벽 요구 사항 (7844): https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/
- cloudflared 실행 파라미터 (`protocol`): https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/cloudflared-parameters/run-parameters/
- 원본 파라미터 (`noTLSVerify`, `originServerName`): https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/cloudflared-parameters/origin-parameters/
- 기본 대시보드의 터널 관리 (2026-02-20 변경 기록): https://developers.cloudflare.com/changelog/2026-02-20-tunnel-core-dashboard
- Zero Trust 설정·결제 프로필 (결제 정보 단계, 부분 확인): https://developers.cloudflare.com/cloudflare-one/setup/ , https://developers.cloudflare.com/billing/create-billing-profile/
