# ADR-0012 CI 보안 도구: gitleaks, bandit, pip-audit, Trivy

- 상태: 채택 (2026-11-11)
- 표기: 결정 **[Claude 제안]** / 공통 기준은 설계 문서 §24.1
- 이 ADR은 도구 하나를 고르는 것이 아니라 **위협별로 도구를 하나씩** 고른다. 그래서 가중 점수 대신 위협 대응표와 후보 비교표를 쓴다.

## 결정
| 위협 | 도구 | 실패 조건 |
|---|---|---|
| 비밀(토큰, 키, 비밀번호)이 Git에 커밋됨 | **gitleaks** | 탐지 1건 이상 |
| Python 코드의 위험한 패턴 (`subprocess(shell=True)`, `yaml.load`, 약한 난수, 하드코딩 비밀번호 등) | **bandit** | High 이상 |
| 알려진 취약점이 있는 Python 의존성 | **pip-audit** (+ Dependabot) | 수정 가능한 취약점 |
| 컨테이너 이미지 OS·라이브러리 취약점, 매니페스트 설정 오류, SBOM | **Trivy** (image, config, sbom) | Critical 또는 수정 가능한 High, securityContext 누락 등 |

## 맥락
- 저장소를 **공개**로 둔다 (Actions 무료 무제한, GHCR 무료). 공개 저장소에서 비밀 커밋은 즉시 사고이므로 gitleaks는 필수다.
- 이 프로젝트의 주장(보안 구현)을 CI 결과로도 보여줘야 한다.
- **2026년 3월 Trivy 공급망 사고**: 공격자가 탈취한 자격 증명으로 악성 Trivy v0.69.4를 배포하고, `aquasecurity/trivy-action`의 태그 77개 중 76개와 `setup-trivy`의 태그 전부를 자격 증명 탈취 코드로 강제 변경했다 (CVE-2026-33634). 보안 도구 자체가 공격 경로가 될 수 있다는 사례다.

## 비교 후보
| 영역 | 채택 | 대안 | 채택 이유 |
|---|---|---|---|
| 비밀 스캔 | gitleaks (MIT) | trufflehog (AGPL-3.0, 실제 유효성 검증 기능), detect-secrets (Apache-2.0), GitHub secret scanning(공개 저장소 무료) | 단일 바이너리, 빠름, pre-commit 훅과 CI 양쪽에서 같은 규칙 사용. GitHub secret scanning과 push protection도 **함께 켠다** (중복 방어) |
| 코드 정적 분석 | bandit (Apache-2.0) | Semgrep CE (LGPL-2.1), CodeQL (공개 저장소 무료) | Python 전용으로 가볍고 규칙이 명확해 오탐 관리가 쉬움. 여유가 있으면 CodeQL을 추가 (공개 저장소 무료) |
| 의존성 취약점 | pip-audit (Apache-2.0, PyPA) | Safety (취약점 DB 상업 이용 조건 있음), osv-scanner (Apache-2.0), Dependabot | PyPA 공식 도구, OSV/PyPI 취약점 DB 사용, 라이선스 제약 없음. Dependabot은 수정 PR 자동 생성용으로 병행 |
| 이미지·설정 스캔 | Trivy (Apache-2.0) | Grype + Syft (Apache-2.0), Docker Scout(무료 범위 제한), Snyk(무료 범위 제한) | 이미지, K8s 매니페스트, SBOM을 **한 도구로** 처리. 대안 1순위는 Grype + Syft |

## 왜 이것인가
1. 공개 저장소 + 1인 개발에서 가장 흔하고 피해가 큰 사고(비밀 커밋, 취약 의존성, 취약 이미지)를 각각 하나의 도구로 막는다.
2. 모두 오픈소스이고 무료이며 CI에서 몇 분 안에 끝난다.
3. 결과를 README 배지와 릴리스 SBOM으로 공개해 "보안이 기능처럼 검증된다"를 보여준다.

## Trivy 사고에서 얻은 운영 규칙
- 서드파티 Action은 **태그가 아니라 커밋 SHA로 고정**한다. 태그는 강제 변경될 수 있다.
- Trivy 바이너리는 버전과 체크섬(또는 서명)을 고정해 설치한다. `latest`를 쓰지 않는다.
- 스캔 job에는 비밀을 주지 않는다. `permissions: contents: read`만 준다. 레지스트리 푸시 권한이 필요한 job과 분리한다.
- CI에는 클러스터 자격 증명이 없다 (배포는 Tailscale을 통한 수동 또는 pull 방식).
- 이 사고를 README의 "공급망" 절에 사례로 인용한다.

## 포기한 것 (트레이드오프)
- trufflehog의 "찾은 비밀이 실제로 유효한지 검증" 기능은 쓰지 않는다.
- Semgrep/CodeQL 수준의 데이터 흐름 분석은 기본에서 빠진다 (선택 추가).
- 도구 네 개의 오탐을 관리하는 비용이 든다 → 예외는 파일로 관리하고 사유를 적는다.

## 결정을 바꾸게 될 조건
- Trivy 배포 채널이 다시 신뢰를 잃으면: Grype + Syft로 교체.
- 데이터 흐름 기반 취약점(SQL 인젝션 경로 등)이 문제가 되면: CodeQL 추가.

## 면접용 한 줄 답변
"위협마다 도구를 하나씩 붙였습니다. 비밀 커밋은 gitleaks, 코드 패턴은 bandit, 의존성은 pip-audit, 이미지와 매니페스트는 Trivy입니다. 2026년 3월에 Trivy Action 태그가 탈취된 사고가 있어서, 액션은 커밋 SHA로 고정하고 스캔 job에는 비밀을 주지 않는 규칙도 함께 넣었습니다."

## 근거 URL
- Trivy 공급망 사고 공식 권고: https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23
- Microsoft 분석: https://www.microsoft.com/en-us/security/blog/2026/03/24/detecting-investigating-defending-against-trivy-supply-chain-compromise/
- gitleaks: https://github.com/gitleaks/gitleaks
- bandit: https://bandit.readthedocs.io/
- pip-audit: https://github.com/pypa/pip-audit
- Trivy: https://trivy.dev/
- GitHub secret scanning: https://docs.github.com/en/code-security/secret-scanning/introduction/about-secret-scanning
- GitHub Actions 보안 강화(SHA 고정): https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions
