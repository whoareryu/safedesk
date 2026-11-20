# ADR-0005 데이터베이스: PostgreSQL

- 상태: 채택 (2026-11-11)
- 표기: 결정 **[Claude 제안]** / 공통 기준은 설계 문서 §24.1

## 결정
relay-db, safedesk-db, minishop-db 모두 **PostgreSQL**을 쓴다.

## 맥락
DB 선택 기준은 성능이 아니라 **권한 통제를 DB 안에서 얼마나 정확하게 표현할 수 있는가**이다.
- 역할 분리: `relay_api`는 암호문 컬럼에 INSERT만, `relay_reveal`은 SELECT만 (컬럼 단위 권한).
- 감사 로그 append-only: UPDATE/DELETE 권한 없음 + 트리거로 차단 + 쓰기는 `SECURITY DEFINER` 함수 하나로만.
- 작업 큐: `FOR UPDATE SKIP LOCKED`.
- 향후 행 단위 격리(앱별·주체별)를 위한 RLS.

## 비교 후보
PostgreSQL, MySQL/MariaDB, SQLite, MongoDB

## 비교표
| 후보 | 필수 조건 | C2 (25%) | C3 (25%) | C4 (20%) | C5 (10%) | C6 (10%) | C7 (10%) | 가중 합 |
|---|---|---|---|---|---|---|---|---|
| **PostgreSQL** | 통과 | 4 | 5 | 4 | 5 | 5 | 5 | **4.55** |
| MySQL / MariaDB | 통과 | 4 | 3 | 4 | 4 | 5 | 5 | 3.95 |
| SQLite | **탈락 (G4)**: DB 사용자·역할 개념이 없어 권한 분리를 DB에서 표현할 수 없음 | 5 | 1 | 5 | 5 | 4 | 3 | 3.70 |
| MongoDB | 통과 | 3 | 3 | 3 | 2 | 4 | 4 | 3.10 |

기능별 비교:
| 기능 | PostgreSQL | MySQL 8 / MariaDB | SQLite | MongoDB |
|---|---|---|---|---|
| 컬럼 단위 GRANT | ○ | ○ | × | × (필드 단위는 뷰/프로젝션으로 우회) |
| Row Level Security | ○ 기본 기능 | × (뷰로 우회) | × | △ (뷰, 애플리케이션 레벨) |
| 트리거로 UPDATE/DELETE 차단 | ○ | ○ | ○ (역할이 없어 의미 약함) | △ (변경 스트림은 사후 탐지) |
| `SECURITY DEFINER` 함수로 쓰기 경로 하나로 제한 | ○ | ○ (`SQL SECURITY DEFINER` 프로시저) | × | × |
| `SKIP LOCKED` 큐 | ○ | ○ (8.0+) | × | △ |
| 감사 확장 | pgaudit | Enterprise Audit / MariaDB audit plugin | × | Enterprise 감사 |
| 라이선스 | PostgreSQL License (매우 관대) | GPLv2 (MySQL은 Oracle 소유, 듀얼 라이선스) | 퍼블릭 도메인 | SSPL (OSI 승인 오픈소스 아님) |
| 메모리 | `shared_buffers` 등으로 작게 조정 쉬움 | 조정 가능 | 매우 작음 | WiredTiger 캐시 기본값이 (RAM−1GB)의 50%라 반드시 줄여야 함 |

## 왜 이것인가
1. 이 프로젝트의 DB 쪽 보안 주장(역할별 컬럼 권한, append-only 감사 로그, RLS로 확장 가능)을 **모두 기본 기능으로** 표현할 수 있는 유일한 후보다.
2. 라이선스가 가장 관대해서 제품화 로드맵과 충돌하지 않는다.
3. 공식 이미지가 arm64를 지원하고, 작은 메모리로 조정하기 쉽다.
4. 한국 실무에서도 MySQL과 함께 가장 흔하다.

## 포기한 것 (트레이드오프)
- MySQL에 익숙한 국내 레거시 환경과의 직접 연관성은 조금 줄어든다.
- MongoDB의 클라이언트 측 필드 암호화(CSFLE) 같은 "DB 드라이버 수준 암호화" 경험은 하지 않는다. 이 프로젝트는 암호화를 DB 밖(Relay + OpenBao)에 두는 것이 핵심이라 의도적으로 포기한다.
- 인스턴스 3개를 띄우므로 메모리를 더 쓴다 (각 256~512 MB, 추정).

## 결정을 바꾸게 될 조건
- 메모리가 부족하면: 앱 DB 두 개를 한 인스턴스의 다른 database와 role로 합친다 (relay-db는 분리 유지).
- 감사 로그 양이 많아지면: 파티셔닝 또는 외부 append-only 저장소(오브젝트 스토리지)로 이전.

## 면접용 한 줄 답변
"성능보다 권한 표현력이 기준이었습니다. 컬럼 단위 권한, 행 단위 보안, SECURITY DEFINER 함수로 감사 로그를 INSERT 전용으로 만드는 걸 모두 기본 기능으로 할 수 있는 게 PostgreSQL이었고, SQLite는 DB 사용자 개념이 없어 처음부터 제외했습니다."

## 근거 URL
- PostgreSQL 권한(컬럼 단위 GRANT): https://www.postgresql.org/docs/current/sql-grant.html
- PostgreSQL RLS: https://www.postgresql.org/docs/current/ddl-rowsecurity.html
- PostgreSQL `SECURITY DEFINER`: https://www.postgresql.org/docs/current/sql-createfunction.html
- `SKIP LOCKED`: https://www.postgresql.org/docs/current/sql-select.html
- MySQL 권한 수준: https://dev.mysql.com/doc/refman/8.0/en/privileges-provided.html
- MongoDB SSPL: https://www.mongodb.com/legal/licensing/server-side-public-license
- MongoDB WiredTiger 캐시 기본값: https://www.mongodb.com/docs/manual/core/wiredtiger/
