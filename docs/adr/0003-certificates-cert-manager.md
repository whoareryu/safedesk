# ADR-0003 인증서: cert-manager + Let's Encrypt

- 상태: 채택 (2026-11-11), **갱신: DNS-01 (2026-11-20)**
- 표기: 결정 **[Claude 제안]** / 공통 기준은 설계 문서 §24.1

## 결정
**cert-manager**로 Let's Encrypt 인증서(HTTP-01)를 발급·갱신한다. 같은 cert-manager로 클러스터 내부 CA를 만들어 OpenBao 등 내부 구간 TLS 인증서도 발급한다.

## 맥락
- 외부 호스트 3개(SafeDesk, MiniShop, Relay)에 공인 인증서가 필요하다.
- 내부 구간(OpenBao 8200 등)도 TLS로 보호하고 싶다.
- 도메인은 DuckDNS이다. Cloudflare처럼 도메인의 네임서버를 옮겨야 하는 서비스는 쓸 수 없다.

## 비교 후보
cert-manager + Let's Encrypt, Traefik 내장 ACME, Cloudflare(프록시 인증서/Origin CA, Tunnel)

## 비교표
| 후보 | 필수 조건 | C2 (25%) | C3 (25%) | C4 (20%) | C5 (10%) | C6 (10%) | C7 (10%) | 가중 합 |
|---|---|---|---|---|---|---|---|---|
| **cert-manager + LE** | 통과 | 4 | 5 | 4 | 5 | 5 | 5 | **4.55** |
| Traefik 내장 ACME | 통과 | 5 | 3 | 5 | 5 | 3 | 2 | 4.00 |
| Cloudflare | 부분 탈락: DuckDNS 도메인을 Cloudflare 존으로 옮길 수 없어 유료 도메인 구매가 필요 (G1 위반 가능) | 5 | 2 | 4 | 3 | 4 | 2 | 3.45 |

근거 메모:
- Traefik 내장 ACME: 가장 간단하다. 하지만 인증서를 Traefik 자체 저장소(acme.json)에 두기 때문에 여러 인스턴스가 공유할 수 없다고 Traefik 문서가 밝힌다. 인증서가 쿠버네티스 Secret이 아니어서 다른 컴포넌트(OpenBao 내부 TLS)가 쓸 수 없다. Traefik 공식 블로그도 HA에는 cert-manager를 권한다.
- cert-manager: 컨트롤러, webhook, cainjector 3개 Pod로 메모리가 조금 든다 (합계 100~200 MB, 추정). 대신 인증서가 `Certificate` 리소스와 Secret으로 남아 선언형으로 관리되고, 내부 CA(`ClusterIssuer` type CA)도 같은 방식으로 만든다. CNCF 프로젝트, Apache-2.0.
- Cloudflare: TLS가 Cloudflare 에지에서 종료되므로 "내 클러스터가 직접 HTTPS를 제공하고 설정을 검증할 수 있다"는 시연(S11)이 약해진다.

## 왜 이것인가
1. 외부 인증서와 내부 CA를 **한 가지 도구, 한 가지 방식**으로 관리한다. 내부 구간 TLS는 "클러스터 안이라고 평문으로 두지 않는다"는 주장의 근거가 된다.
2. 인증서가 쿠버네티스 리소스로 남으므로 상태를 `kubectl get certificate`로 확인하고 증거로 남길 수 있다.
3. 실무 표준이라 그대로 이력서에 쓸 수 있다.

## 포기한 것 (트레이드오프)
- Traefik 내장 ACME보다 구성요소가 늘고 메모리를 조금 더 쓴다.
- HTTP-01 솔버 Pod가 앱 네임스페이스에 생기므로 NetworkPolicy에 솔버 허용 규칙(포트 8089)을 따로 넣어야 한다.

## 결정을 바꾸게 될 조건
- 와일드카드 인증서가 필요해지면: DuckDNS DNS-01 webhook 추가.
- 메모리가 아주 부족해지면: 외부 인증서만 Traefik ACME로 돌리고 내부 TLS는 OpenBao PKI로 대체.

## 운영 주의 (비용·한도)
- Let's Encrypt 한도: 등록 도메인당 7일에 인증서 50개 등. `duckdns.org`는 Public Suffix List에 있으므로 각 DuckDNS 서브도메인이 독립된 등록 도메인으로 계산된다. 그래도 실험은 **staging 발급자로 먼저** 한다.

## 면접용 한 줄 답변
"외부 공인 인증서와 클러스터 내부 CA를 같은 선언형 도구로 관리하려고 cert-manager를 썼습니다. Traefik 내장 ACME는 인증서가 Traefik 안에만 저장돼서 OpenBao 같은 다른 컴포넌트가 쓸 수 없었습니다."

## 근거 URL
- Traefik ACME 문서(저장소 공유 불가): https://doc.traefik.io/traefik/reference/install-configuration/tls/certificate-resolvers/acme/
- Traefik 블로그(cert-manager와 함께 쓰기): https://traefik.io/blog/secure-web-applications-with-traefik-proxy-cert-manager-and-lets-encrypt
- Let's Encrypt 한도: https://letsencrypt.org/docs/rate-limits/
- DuckDNS의 Public Suffix List 등재: https://bugzilla.mozilla.org/show_bug.cgi?id=1165730

## 갱신 (2026-11-20): HTTP-01 → DNS-01 (Cloudflare) **[사용자 결정]** U25
- 결정: cert-manager + Let's Encrypt는 유지하고, 챌린지를 **DNS-01(Cloudflare)**로 바꾼다. `ClusterIssuer` `letsencrypt-staging`/`letsencrypt-prod`의 solver는 `dns01.cloudflare`뿐이고 HTTP-01 solver는 두지 않는다. staging 먼저, prod는 전환 가드 스크립트로만 (기존과 같음).
- 맥락 변화: 도메인이 DuckDNS에서 사용자의 기존 개인 도메인 `whoareryu.cloud`(네임서버 Cloudflare)로 바뀌었다. 공개 경로가 Cloudflare 터널이라 HTTP-01 요청이 원본에 직접 닿지 않는다 (ADR-0014, ADR-0015).
- 비교표의 Cloudflare 행 탈락 근거("DuckDNS 도메인을 Cloudflare 존으로 옮길 수 없음")는 사라졌다. 그래도 인증서 발급 도구로는 cert-manager를 유지한다. Cloudflare는 에지 인증서(Universal SSL)를 맡고, 원본 구간은 cert-manager 인증서로 Full (strict) 검증을 한다. 내부 CA 용도도 그대로다.
- API 토큰 **[사용자 결정]**: 이 zone 하나, 권한 Zone·DNS·Edit, 집 공인 **IPv4** 필터, 6개월 만료. Zone·Zone·Read는 cert-manager Cloudflare solver가 zone ID를 조회하는 데 **기술적으로 필요**해 더했다 → 사용자 승인 2026-11-20 (원래 사용자 결정은 "zone DNS 편집만", U25·U35). Cloudflare API 호출은 IPv4로 강제하고, cert-manager 이그레스가 IPv4인지 M1에서 확인한다. 원본은 Mac 키체인, 클러스터에는 `cert-manager` ns Secret(키 `api-token`) 하나.
- 포기한 것 갱신: 기존 "HTTP-01 솔버 Pod 때문에 NP 허용 규칙(N5) 필요"는 없어졌다 (설계 문서 §10 N5 폐지). 대신 토큰이 zone 레코드를 고칠 수 있어 apex/www(Vercel)까지 영향 줄 수 있는 폭발 반경이 생겼다 (설계 문서 §16, §22).
- 운영 주의 갱신: `whoareryu.cloud`는 등록 도메인 하나라 Let's Encrypt 주간 한도를 apex/www(Vercel)의 인증서 발급과 공유할 수 있다. prod 재발급을 반복하지 않는다. CAA 레코드가 Let's Encrypt를 막지 않는지 M1에서 먼저 확인한다.
- 근거 (2026-11-20 조회): cert-manager Cloudflare DNS-01 https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/ , ClusterIssuer Secret 위치 https://cert-manager.io/docs/configuration/
