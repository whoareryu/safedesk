# ADR-0006 백엔드 프레임워크: Python + FastAPI

- 상태: 채택 (2026-11-11)
- 표기: **[사용자 결정]**. 이 ADR은 결정을 바꾸려는 것이 아니라, 그 결정이 이 프로젝트의 제약 안에서 타당한지 **대안과 비교해 확인**한 기록이다. 사후 정당화가 되지 않도록 FastAPI가 불리한 항목도 그대로 적는다.
- 공통 기준은 설계 문서 §24.1

## 결정
PII Relay, SafeDesk, MiniShop을 모두 **Python + FastAPI**로 만든다.

## 맥락
- 서비스가 세 개(Relay는 프로세스 두 개)라 프로세스당 메모리가 곧 비용이다. 12 GB 중 Ollama가 4 GB를 쓴다.
- Relay는 다른 앱이 쓰는 **API 제품**이므로 입력 스키마를 엄격하게 검증하고, API 문서가 자동으로 나와야 SDK와 계약을 맞추기 쉽다.
- 마스킹(정규식, 한국어 텍스트 처리), LLM 호출, 테스트셋 평가 같은 일은 Python 생태계가 편하다.

## 비교 후보
FastAPI, Django, Flask, Spring Boot

## 비교표
| 후보 | C2 (25%) | C3 (25%) | C4 (20%) | C5 (10%) | C6 (10%) | C7 (10%) | 가중 합 |
|---|---|---|---|---|---|---|---|
| **FastAPI** | 5 | 4 | 5 | 5 | 4 | 5 | **4.65** |
| Django | 4 | 4 | 4 | 5 | 4 | 5 | 4.20 |
| Flask | 5 | 3 | 4 | 5 | 4 | 5 | 4.20 |
| Spring Boot | 2 | 5 | 2 | 5 | 5 | 5 | 3.65 |

항목별 메모:
| 관점 | FastAPI | Django | Flask | Spring Boot |
|---|---|---|---|---|
| 프로세스 메모리 (추정) | 50~100 MB | 80~150 MB | 40~80 MB | 200~400 MB (JVM) |
| 입력 검증 | pydantic 기본. `extra="forbid"`로 모르는 필드 거부 → 대량 할당(mass assignment) 방지 | Form/DRF serializer | 별도 라이브러리 필요 | Bean Validation |
| API 문서 | OpenAPI 자동 생성 | DRF 등 추가 | 추가 | springdoc 추가 |
| 보안 기본기 | 직접 조립해야 함 (CSRF, 세션) | **CSRF, 세션, 인증 기본 내장** | 직접 조립 | **Spring Security가 가장 성숙** |
| 비동기 I/O (Relay·OpenBao 호출) | 기본 | 부분 지원 | 제한적 | WebFlux 별도 |
| 이 프로젝트와의 충돌 | 없음 | 기본 관리자 화면(admin)은 "관리자가 데이터를 보는 화면"이라 오히려 꺼야 함 | 없음 | 메모리 |
| 한국 채용 시장 | 증가 중 | 보통 | 보통 | **가장 흔함** |

## 왜 이것인가
1. **메모리**: 프로세스 다섯 개를 12 GB 노드에 올려야 한다. JVM 기반은 프로세스당 수백 MB가 들어 Ollama와 함께 올리기 어렵다.
2. **입력 검증이 곧 보안 기능**: Relay는 설정에 없는 필드를 거부해야 한다(§7.4). pydantic 모델로 선언하면 검증, 에러 형식, OpenAPI 문서가 한 번에 맞춰진다.
3. **Relay가 API 제품이라는 점**: 자동 생성된 OpenAPI 스펙이 SDK와의 계약서가 된다.
4. 마스킹·LLM 쪽 작업과 같은 언어를 써서 1인 개발의 문맥 전환을 줄인다.

## 포기한 것 (트레이드오프)
- Django나 Spring Security가 기본으로 주는 CSRF·세션·인증 기능을 직접 조립해야 한다. 실수할 여지가 있으므로 이 부분은 테스트(쿠키 속성, CSRF 거부, 세션 만료)를 따로 둔다.
- 한국 시장에서 가장 흔한 Spring Boot 경험은 쌓이지 않는다. 대신 "보안 설계와 증명"이 언어와 무관하게 옮겨 갈 수 있는 역량이라고 설명한다.
- Python은 CPU 바운드 작업에 느리다. 이 프로젝트에서 CPU 바운드는 LLM뿐이고 Ollama가 처리한다.

## 결정을 바꾸게 될 조건
- 메모리 제약이 풀리고 대상 기업이 Spring 중심이면: Relay만 Spring Boot로 다시 만들어 "같은 API 계약, 다른 구현"을 보여주는 것도 좋은 확장이다.
- 관리 화면이 많이 필요해지면: Django가 유리하다. 단, 기본 admin은 PII를 다루지 않는 화면에만 쓴다.

## 면접용 한 줄 답변
"처음엔 익숙해서 고른 것이 맞지만, 다시 따져 봐도 맞는 선택이었습니다. 12GB 노드에 서비스 다섯 개를 올려야 해서 JVM은 부담이었고, Relay는 모르는 필드를 거부하는 게 보안 요구라 pydantic 스키마 검증과 자동 OpenAPI 문서가 직접 도움이 됐습니다. 대신 Django나 Spring이 기본으로 주는 CSRF·세션 처리는 직접 만들고 테스트로 막았습니다."

## 근거 URL
- FastAPI 문서(검증, OpenAPI): https://fastapi.tiangolo.com/
- pydantic `extra="forbid"`: https://docs.pydantic.dev/latest/api/config/#pydantic.config.ConfigDict.extra
- Django CSRF: https://docs.djangoproject.com/en/stable/ref/csrf/
- Spring Security: https://docs.spring.io/spring-security/reference/
- (메모리 수치는 일반적인 경험치에 근거한 추정. M2에서 실제 RSS를 측정해 이 ADR을 갱신한다)
