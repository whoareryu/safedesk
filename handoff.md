# Handoff — 다음 세션 시작점

> 사용자가 "handoff 확인해서 작업 진행해줘"라고 하면, 이 파일을 끝까지 읽고 **"다음 세션이 할 일"** 순서대로 바로 진행한다. 다시 기획하거나 질문부터 하지 않는다.

- 작성일: 2026-11-11
- 현재 상태: 기획 완료, 코드 없음. 다음 작업은 **M1 Task 1**.

## 1. 프로젝트 한 줄 요약

AI 고객문의 서비스(SafeDesk)와 가벼운 데모 앱(MiniShop)이 같은 **PII Relay**를 끼워 쓰는 구조를 K3s 위에서 0원으로 운영하는 보안 포트폴리오다. 목표는 "고객도, 프로젝트 주인도 개인정보를 함부로 볼 수 없고, 보면 반드시 흔적이 남는다"를 공격 시연으로 증명하는 것.

## 2. 꼭 읽을 파일

| 파일 | 용도 |
|---|---|
| `docs/2026-11-11-secure-ax-k3s-design.md` | 기획서 (v4, 승인됨). §4 사용자 결정 U1~U20 |
| `docs/adr/0001~0013` | 기술 선정 근거 (면접 대비) |
| `docs/superpowers/plans/2026-11-11-m1-infra-foundation.md` | **M1 구현 계획 (Task 1~11)**. 실행 기준 문서 |

## 3. 확정된 진행 방식

- **실행 방식: Native.** 사용자가 선택했다. 이 세션의 Claude가 `superpowers:executing-plans` 스킬로 계획을 Task 단위로 직접 실행하고, M1이 끝나면 독립 리뷰어 한 명이 전체를 점검한다.
- **절차:** 각 Task는 "검증 스크립트 먼저 → 실패 확인 → 구현/적용 → 통과 확인 → 커밋" 순서로 진행한다.
- **사용자가 직접 해야 하는 단계:** OCI 콘솔, DuckDNS 가입, Tailscale 로그인, 재부팅 확인은 사용자 몫이다. 그 단계에 오면 할 일을 짧게 안내하고, 결과(출력이나 캡처)를 받아서 이어간다.
- **지켜야 할 원칙:**
  - 비용 0원 (기획서 §19.2 CG1~CG10)
  - 비밀값 커밋 금지 (저장소는 public 전제)
  - 기술을 선택할 때마다 선정 근거와 비교 대안을 남긴다

## 4. 다음 세션이 할 일 — M1 Task 1: 저장소 뼈대와 비밀 위생

상세는 계획 파일의 "Task 1"이 기준이다. 아래는 바로 시작하기 위한 요약이다.

### 4.0 사전 준비 (Mac, 처음 한 번)

2026-11-11 기준으로 이 Mac에 **없는** 도구는 `pre-commit`, `gitleaks`, `nmap`, `helm`, `shellcheck`다. `git`, `kubectl`, `tailscale`, `brew`는 있다.

- Task 1에 필요한 것: `brew install pre-commit gitleaks shellcheck`
- 이후 Task에 필요한 것(지금 같이 설치해도 됨): `brew install nmap helm`
- 설치 명령은 사용자 확인 후 실행한다.

### 4.1 만들 파일

| 파일 | 내용 |
|---|---|
| `.gitignore` | `config/cluster.env`, `*.kubeconfig`, `kubeconfig*`, `.env*`, `docs/evidence/**/raw/` |
| `.pre-commit-config.yaml` | gitleaks hook (rev는 설치된 최신 안정판으로 고정) |
| `.gitleaks.toml` | 기본 규칙 + DuckDNS 토큰(UUID 형식), Tailscale auth key(`tskey-`) 규칙 추가 |
| `config/cluster.env.example` | 변수 이름만: `PUBLIC_IP TS_IP HOST_SAFEDESK HOST_MINISHOP HOST_RELAY ACME_EMAIL K3S_VERSION` |
| `scripts/lib/assert.sh` | `assert_eq <expected> <actual> <msg>`, `assert_contains <haystack> <needle> <msg>`, `assert_fails <msg> -- <cmd...>`, `assert_succeeds <msg> -- <cmd...>`, `assert_summary` (`PASS n / FAIL m`, 실패가 있으면 exit 1) |
| `scripts/lib/env.sh` | `load_env`: `config/cluster.env`를 source하고, 위 변수 중 빈 값이 있으면 이름을 출력하고 exit 2 |
| `tests/scripts/run.sh` | `tests/scripts/test_*.sh`를 모두 실행하고, 하나라도 실패하면 exit 1 |
| `tests/scripts/test_assert.sh` | assert 라이브러리 자체 테스트 |
| `Makefile` | `test-scripts` 타깃 (`verify-m1`은 Task 11에서 채움) |

### 4.2 순서

1. `git init -b main`, `.gitignore` 작성
2. **실패하는 테스트 작성:** `tests/scripts/test_assert.sh`에 아래 경우를 넣는다. 각 경우는 서브셸에서 돌려 종료 코드를 확인한다.
   - `assert_eq a a`는 통과
   - `assert_eq a b`는 실패로 집계
   - `assert_fails "x" -- false`는 통과
   - `assert_fails "x" -- true`는 실패로 집계
   - 실패가 1건이면 `assert_summary`의 종료 코드가 1
3. `make test-scripts` 실행 → `assert.sh`가 없어서 **FAIL**인지 확인
4. `assert.sh`, `env.sh`, `run.sh`, `Makefile` 구현
5. `make test-scripts` 실행 → **PASS** 확인
6. `pre-commit install` 후 비밀값 차단 확인:
   - `config/leak-test.txt`에 `DUCKDNS_TOKEN=<UUID 형식 가짜값>`을 넣는다.
   - `git add` 후 커밋을 시도해서 gitleaks가 **거부**하는지 확인한다.
   - 확인 후 파일을 삭제한다.
7. 첫 커밋. 기존 `docs/`와 이 `handoff.md`도 포함한다.

   ```
   chore: repo skeleton, assert lib, gitleaks pre-commit

   Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
   ```

### 4.3 Task 1 완료 기준

- `make test-scripts` PASS
- 가짜 토큰 커밋이 gitleaks로 거부됨
- 첫 커밋 완료, `git status` clean

## 5. Task 1 다음

- **Task 2:** OCI VM 생성. 사용자가 콘솔에서 직접 만든다. 계획 파일 Task 2의 런북 순서를 따른다.
- **ARM 용량 부족 시:** "Out of capacity"로 생성이 안 되면 기획서 §19.3 대안 A(로컬 Mac VM, `k8s/overlays/local`)로 전환할지 사용자에게 묻는다.
- **작업 끝날 때:** 이 `handoff.md`의 "현재 상태"와 "다음 세션이 할 일"을 다음 Task 기준으로 갱신한다.

## 6. 기억해 둘 사실 (조사로 확인됨)

- OCI Always Free A1: 2026-06에 **2 OCPU / 12 GB**로 축소됐다. PAYG 업그레이드는 금지.
- ingress-nginx: 2026-03 EOL. Traefik을 선택한 근거 중 하나.
- trivy-action 태그 탈취 사고(2026-03, CVE-2026-33634): GitHub Action은 커밋 SHA로 고정한다.
- Gemini 무료 티어는 입력 데이터가 Google 제품 개선에 쓰일 수 있어 사용하지 않는다. LLM은 Ollama 전용.
