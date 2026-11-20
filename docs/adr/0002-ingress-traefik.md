# ADR-0002 인그레스: Traefik (K3s 기본)

- 상태: 채택 (2026-11-11)
- 표기: 결정 **[Claude 제안]** / 공통 기준은 설계 문서 §24.1

## 결정
K3s에 기본 포함된 **Traefik v3**를 인그레스 컨트롤러로 쓴다. 표준 `Ingress` 리소스와 Traefik Middleware CRD(Headers, RateLimit, RedirectScheme, Buffering, IPAllowList)를 조합한다. 이후 Gateway API로 옮길 수 있게 라우팅 규칙을 단순하게 유지한다.

## 맥락
- 외부에 열리는 유일한 진입점이므로 TLS 종료, 보안 헤더, rate limit, 경로별 보호를 여기서 처리해야 한다.
- 메모리를 아껴야 하고, 1인 운영이라 별도 설치·업그레이드할 구성요소를 줄이고 싶다.
- 2026년 3월 **ingress-nginx가 지원 종료(EOL)**되어 저장소가 보관 처리되었고 더 이상 보안 패치가 나오지 않는다.

## 비교 후보
Traefik, ingress-nginx, HAProxy Kubernetes Ingress, Caddy(ingress controller), Gateway API 구현체(Envoy Gateway 등)

## 비교표
| 후보 | 필수 조건 | C2 (25%) | C3 (25%) | C4 (20%) | C5 (10%) | C6 (10%) | C7 (10%) | 가중 합 |
|---|---|---|---|---|---|---|---|---|
| **Traefik (K3s 기본)** | 통과 | 5 | 4 | 5 | 5 | 4 | 4 | **4.55** |
| HAProxy Ingress | 통과 | 4 | 4 | 3 | 5 | 3 | 4 | 3.80 |
| Envoy Gateway (Gateway API) | 통과 | 3 | 5 | 2 | 5 | 4 | 5 | 3.80 |
| Caddy ingress | 통과 | 4 | 3 | 3 | 5 | 2 | 3 | 3.35 |
| ingress-nginx | **탈락 (G3)**: 2026-03-24 EOL, 저장소 보관, 보안 패치 없음 | — | — | — | — | — | — | — |

근거 메모:
- Traefik: 이미 설치되어 있어 추가 메모리가 0이다. 미들웨어로 HSTS·CSP·rate limit·IP allowlist를 선언형으로 붙일 수 있다. Gateway API도 지원하므로 나중에 옮겨 갈 길이 있다. 라이선스 MIT.
- Envoy Gateway: Gateway API의 표준 구현으로 이식성과 정책 표현력이 가장 좋다. 하지만 Envoy 프록시와 컨트롤러를 따로 띄워야 해서 메모리와 학습 비용이 크다 (추정).
- HAProxy Ingress: 성능과 안정성이 좋지만 K3s 기본 Traefik을 끄고 새로 넣어야 하고, 이 프로젝트에서 얻는 추가 보안 기능이 크지 않다.
- Caddy: 자동 HTTPS가 강점이지만 쿠버네티스 인그레스 컨트롤러는 커뮤니티 프로젝트라 실무 채택도가 낮다.

## 왜 이것인가
1. 추가 비용(메모리, 설치, 업그레이드)이 0이다. K3s가 Helm 차트로 관리해 주고 `HelmChartConfig`로 값만 바꾸면 된다.
2. 이 프로젝트가 필요로 하는 보안 기능(HTTPS 리다이렉트, 보안 헤더, rate limit, 본문 크기 제한, IP allowlist, 최소 TLS 버전)이 모두 미들웨어로 있다.
3. ingress-nginx 지원 종료 이후 실무에서도 Traefik이나 Gateway API로 옮기는 흐름이 있어, 이 선택은 시장 흐름과도 맞다.

## 포기한 것 (트레이드오프)
- Traefik 전용 어노테이션과 CRD에 일부 묶인다 (다른 컨트롤러로 옮길 때 미들웨어를 다시 써야 함).
- Envoy 계열의 세밀한 L7 정책과 관측성은 포기한다.
- Traefik RateLimit은 인스턴스 메모리 기반이라 다중 레플리카에서 정확하지 않다 (단일 노드라 지금은 문제 없음).

## 결정을 바꾸게 될 조건
- Gateway API로 표준화하고 싶어지면: 먼저 Traefik의 Gateway API 프로바이더로 옮기고, 그다음 필요하면 Envoy Gateway.
- WAF 수준의 요청 검사가 필요해지면: Traefik 플러그인 또는 앞단 WAF 추가 검토.

## 면접용 한 줄 답변
"K3s에 기본으로 들어 있어 추가 자원이 들지 않고, 필요한 보안 헤더·rate limit·IP 제한을 미들웨어로 선언할 수 있었습니다. 대안이던 ingress-nginx는 2026년 3월에 지원이 끝나 보안 패치가 없어서 제외했습니다."

## 근거 URL
- Kubernetes 공식 성명(ingress-nginx 은퇴): https://www.kubernetes.io/blog/2026/01/29/ingress-nginx-statement/
- Google 오픈소스 블로그(ingress-nginx 전환): https://opensource.googleblog.com/2026/02/the-end-of-an-era-transitioning-away-from-ingress-nginx.html
- K3s 네트워킹·Traefik: https://docs.k3s.io/networking/networking-services
- K3s HelmChartConfig: https://docs.k3s.io/add-ons/helm
- Traefik v3 미들웨어·TLS 옵션 안내: https://www.bigiron.cc/guides/traefik-v3-kubernetes-ingress-with-middleware-and-tls-options
