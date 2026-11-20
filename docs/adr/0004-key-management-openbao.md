# ADR-0004 키·비밀 관리: OpenBao (Transit + Kubernetes auth + audit)

- 상태: 채택 (2026-11-11)
- 표기: 결정 **[Claude 제안]**. 결정을 이끈 요구사항은 **[사용자 결정]** U4 "DB 개인정보는 암호화 저장, 프로젝트 주인도 함부로 볼 수 없음"
- 공통 기준은 설계 문서 §24.1. 이 ADR은 보안 핵심 컴포넌트이므로 **필수 조건 G4**(아래)를 함께 적용한다.

## 결정
개인정보 암호화 키는 **OpenBao**의 Transit 엔진에만 둔다. 앱과 Relay는 키를 받지 않고 encrypt·decrypt·hmac **연산만 요청**한다. 누가 어떤 연산을 할 수 있는지는 OpenBao 정책(엔드포인트 × 키 단위)과 Kubernetes auth(ServiceAccount 신원)로 정하고, 모든 연산은 audit device에 기록된다.

## 맥락: 이 프로젝트에서 "암호화"가 해야 하는 일
핵심 요구는 "암호화했다"가 아니라 아래 네 가지다. 이것이 필수 조건 G4가 된다.
| 요구 | 의미 |
|---|---|
| R1 키와 데이터 분리 | DB를 통째로 가져가도(덤프, 백업 유출, 운영자 `psql`) 키가 같이 있지 않아야 한다 |
| R2 연산 단위 권한 분리 | "암호화는 되지만 복호화는 안 되는" 신원을 만들 수 있어야 한다 (relay-api vs relay-reveal) |
| R3 연산 단위 감사 | 복호화가 일어날 때마다 누가, 언제, 어떤 키로 했는지 남아야 한다. 운영자가 몰래 복호화하면 흔적이 남아야 한다 |
| R4 키를 꺼낼 수 없음 | 키를 export해서 밖에서 쓰는 길이 기본적으로 막혀 있어야 한다 |

## 비교 후보
OpenBao, HashiCorp Vault, 클라우드 KMS(AWS KMS, GCP Cloud KMS, OCI Vault), Sealed Secrets, SOPS, Infisical, 앱/DB 내 자체 암호화(pgcrypto, Python Fernet)

## 필수 조건 판정
| 후보 | G1 0원 | G3 유지보수 | G4 (R1~R4) | 판정 |
|---|---|---|---|---|
| **OpenBao** | ○ | ○ (Linux Foundation) | R1○ R2○ R3○ R4○ | **통과** |
| HashiCorp Vault | ○ (자체 사용은 BSL 허용) | ○ | R1○ R2○ R3○ R4○ | 통과 |
| AWS KMS / GCP KMS | × (키당 월 과금) | ○ | ○ | 탈락 |
| OCI Vault (KMS) | ○ (소프트웨어 키 무료, HSM 키 버전 20개 무료) | ○ | R1○ R2△ R3○ R4○: 신원이 **인스턴스(노드) 단위**라 같은 노드의 Pod끼리 권한을 나눌 수 없음 | 조건부 통과 |
| Infisical | ○ (코어 MIT) | ○ | 비밀 저장이 주 용도. 연산 단위 정책·감사가 엔터프라이즈 기능과 섞여 있어 확인 필요 | 조건부 통과 |
| Sealed Secrets / SOPS | ○ | ○ | 용도가 다름: Git에 넣는 **배포용 시크릿** 보호. 런타임 필드 암호화 API가 없음 | 평가 대상 아님 (보완재) |
| pgcrypto (DB 내 암호화) | ○ | ○ | R1× R2× R3× R4×: 키를 SQL에 넘겨야 하므로 키가 DB 세션·로그·`pg_stat_statements`에 나타날 수 있고, DB에 접근하는 사람이 키도 가진 앱 설정을 볼 수 있음 | **탈락** |
| Fernet (앱 내 키) | ○ | ○ | R1△ R2× R3× R4×: 키가 앱 환경변수/Secret에 있음. 앱 Pod에 `kubectl exec`할 수 있는 운영자는 모든 레코드를 조용히 복호화할 수 있음 | **탈락** |

## 비교표 (필수 조건 통과 후보)
| 후보 | C2 (25%) | C3 (25%) | C4 (20%) | C5 (10%) | C6 (10%) | C7 (10%) | 가중 합 |
|---|---|---|---|---|---|---|---|
| **OpenBao** | 4 | 5 | 3 | 5 | 3 | 5 | **4.15** |
| HashiCorp Vault | 4 | 5 | 3 | 2 | 5 | 5 | 4.05 |
| OCI Vault | 5 | 3 | 4 | 2 | 3 | 1 | 3.40 |
| Infisical | 3 | 3 | 4 | 4 | 3 | 4 | 3.40 |
| (참고) Fernet | 5 | 1 | 5 | 5 | 4 | 5 | 3.90 — G4 탈락 |
| (참고) pgcrypto | 5 | 1 | 4 | 5 | 3 | 4 | 3.50 — G4 탈락 |

참고 행이 보여주듯, 단순함만 보면 Fernet이 점수가 높다. **그래서 가중 점수보다 필수 조건을 먼저 본다.** Fernet은 "주인도 함부로 못 본다"는 프로젝트의 존재 이유를 만족하지 못한다.

## 왜 이것인가
1. **R2가 결정적이다.** Transit은 `transit/encrypt/<key>`와 `transit/decrypt/<key>`가 다른 경로이므로 정책으로 따로 줄 수 있다. 그래서 "토큰화 서비스는 복호화를 못 한다"(S7)를 설정 한 줄로 만들고 시연으로 증명할 수 있다. 앱 내 키나 pgcrypto로는 키를 가진 쪽이 항상 양방향을 다 할 수 있다.
2. **R3**: OpenBao audit device는 모든 요청을 기록하고, 기록할 수 없으면 요청 자체를 거부한다. "보면 반드시 흔적이 남는다"를 도구 차원에서 보장한다.
3. **신원**: Kubernetes auth로 Pod의 ServiceAccount가 곧 신원이 된다. 정적 토큰을 배포할 필요가 없다. OCI Vault는 노드 단위 신원(instance principal)이라 같은 노드의 relay-api와 relay-reveal을 구분할 수 없다.
4. **Vault 대신 OpenBao인 이유**: 기능과 API는 사실상 같다 (OpenBao는 Vault 1.14의 MPL 2.0 코드에서 갈라져 나왔다). 차이는 라이선스다. Vault는 2023년 8월 BSL 1.1로 바뀌어 경쟁 서비스 제공에 제약이 있다. 이 프로젝트는 §23 제품화 로드맵에서 "PII Relay를 서비스로 판다"는 방향을 적고 있으므로, 그 경우에도 제약이 없는 MPL 2.0 쪽을 골랐다. 자체 사용만 한다면 Vault도 충분히 맞는 선택이라는 점을 숨기지 않는다.
5. derived key(`derived=true` + context)로 사용자·앱별 키를 파생해 암호문 바꿔치기를 막는다 (S9-e).

## 포기한 것 (트레이드오프)
- 운영 부담: 초기화, 언실, 정책 관리, 백업. 재부팅하면 수동 언실이 필요하다 (Shamir).
- 모든 암·복호화가 네트워크 왕복이 된다 (지연 수 ms, 추정). 이 규모에서는 문제가 아니다.
- 실무 채택도는 Vault가 더 높다. 다만 API가 호환되므로 경험은 그대로 옮겨진다.
- Sealed Secrets/SOPS가 주는 "Git에 시크릿을 안전하게 넣기"는 이 결정으로 해결되지 않는다. DB 비밀번호 같은 배포용 시크릿은 K8s Secret(K3s secrets-encryption)으로 두고, 필요하면 SOPS를 보완재로 추가한다 **[빌더 재량]**.

## 결정을 바꾸게 될 조건
- 클라우드 매니지드로 옮기고 워크로드 아이덴티티(Pod 단위 IAM)가 생기면: 클라우드 KMS + envelope 암호화로 운영 부담을 줄일 수 있다.
- 자동 언실이 꼭 필요해지면: OpenBao의 OCI KMS seal(OCI Vault 무료 범위)을 검토한다. 단, 이 경우 신뢰의 뿌리가 "운영자가 가진 OCI 계정"이 되므로 "주인도 함부로 못 본다"는 주장은 약해진다. static seal은 키가 같은 노드에 있게 되므로 쓰지 않는다.

## 면접용 한 줄 답변
"요구사항이 '주인도 몰래 못 본다'였기 때문에 키를 데이터 옆에 두는 pgcrypto나 앱 내 키는 탈락이었습니다. OpenBao Transit은 암호화와 복호화 권한을 서비스별로 나누고 모든 복호화를 감사 로그에 남겨서, 토큰화 서비스는 복호화를 못 한다는 걸 실제로 시연할 수 있었습니다. Vault와 기능은 같지만 BSL 라이선스 때문에 MPL인 OpenBao를 골랐습니다."

## 근거 URL
- OpenBao Transit: https://openbao.org/docs/secrets/transit/ , API(derived/context): https://openbao.org/api-docs/secret/transit/
- OpenBao Kubernetes auth: https://openbao.org/docs/auth/kubernetes/
- OpenBao seal 종류(OCI KMS, static 등): https://openbao.org/docs/configuration/seal/ , https://openbao.org/docs/configuration/seal/static/
- Vault BSL 전환과 OpenBao 포크: https://wz-it.com/en/blog/openbao-vs-vault-comparison/ , https://openbao.org/ecosystem/news/
- OCI Vault 무료 범위: https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm , https://www.oracle.com/security/cloud-security/key-management/
- Infisical 라이선스·자체 호스팅: https://infisical.com/docs/documentation/getting-started/concepts/deployment-models , https://infisical.com/pricing
- Sealed Secrets vs SOPS: https://stackharbor.com/en/knowledge-base/gitops-secrets-sealed-sops-external/
- pgcrypto: https://www.postgresql.org/docs/current/pgcrypto.html
