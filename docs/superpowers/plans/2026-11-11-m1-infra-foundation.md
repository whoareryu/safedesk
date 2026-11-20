# M1 인프라 기초 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OCI Always Free ARM VM 한 대에 K3s를 올리고, 외부에는 80/443만 열린 상태에서 세 DuckDNS 호스트가 Let's Encrypt HTTPS로 더미 앱을 서비스하며, 5개 앱 네임스페이스가 처음부터 PSA `restricted` + default-deny NetworkPolicy 아래에 있음을 스크립트로 증명한다.

**Architecture:** 호스트 설정(VM, 방화벽, Tailscale, K3s, DuckDNS)은 VM에서 실행하는 멱등 셸 스크립트로, 클러스터 설정은 Kustomize(`k8s/base` + `k8s/overlays/{oci,local}`)와 K3s 자동 배포 매니페스트(`HelmChartConfig`)로 관리한다. 모든 완료 기준은 `scripts/verify/` 아래의 검증 스크립트로 표현하고, 각 Task는 "검증 스크립트 작성 → 실패 확인 → 적용 → 통과 → 커밋" 순서를 따른다. 네트워크 정책은 `attacks/netmatrix.sh`가 기대 매트릭스(TSV)와 실측을 비교해 증명한다.

**Tech Stack:** Ubuntu 24.04 arm64, K3s(내장 Traefik v3, ServiceLB, kube-router NetworkPolicy, metrics-server), cert-manager(Helm), Let's Encrypt HTTP-01, DuckDNS, Tailscale Personal, Kustomize, bash, nmap, curl, dig, testssl.sh(선택).

**Spec:** `docs/2026-11-11-secure-ax-k3s-design.md` (§3 제약, §10 네트워크 정책, §11 인그레스, §15 하드닝, §19 무료 인프라·비용 가드레일, §20 M1 행, 부록 A). 근거 ADR: 0001, 0002, 0003, 0008, 0010, 0011.

## Global Constraints

- 비용 0원: OCI는 PAYG 업그레이드 금지, "Always Free 사용 가능" shape만 사용 (CG1). 예산 알림 1달러 (CG2). OCI Load Balancer, 추가 예약 공인 IP, 홈 리전 밖 자원 생성 금지 (CG3). 볼륨 합계 200 GB 이하, 백업 5개 이하 (CG4).
- VM: Ampere A1 Flex **2 OCPU / 12 GB**, Ubuntu 24.04 arm64, 부트 볼륨 100 GB 하나.
- 외부 개방 포트는 **TCP 80, 443만**. OCI Security List/NSG와 호스트 iptables 양쪽에서 강제. 22는 Tailscale SSH 확인 후 공개에서 닫는다.
- K3s API(6443)는 Tailscale 주소로만 접근. K3s 플래그: `--secrets-encryption`, `--write-kubeconfig-mode 600`, `--tls-san <tailscale IPv4>`. Traefik, ServiceLB, local-path, metrics-server, NetworkPolicy 컨트롤러는 끄지 않는다.
- 저장소는 공개 전제: 비밀값(DuckDNS 토큰, ACME 이메일, kubeconfig, Tailscale 키, 공인 IP가 담긴 env)은 커밋 금지. gitleaks pre-commit 필수 (CG5).
- 이미지: `linux/arm64` 지원 이미지만, digest 고정, 가능하면 GHCR (CG6).
- Let's Encrypt: **staging으로 먼저** 검증한 뒤 prod로 전환 (CG7).
- 앱 네임스페이스 5개: `pii-relay`, `safedesk`, `minishop`, `openbao`, `audit-anchor`. 모두 `pod-security.kubernetes.io/enforce: restricted` + ingress/egress default-deny.
- 라벨: 네임스페이스는 `kubernetes.io/metadata.name`, Pod는 `app.kubernetes.io/name`.
- 미들웨어 값(§11.3): HSTS `max-age=31536000; includeSubDomains`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, CSP `default-src 'self'; script-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self' https://<relay 호스트>`, `Server` 헤더 제거. TLS 최소 1.2. Traefik 대시보드 비노출. 접근 로그에 쿼리스트링, `Cookie`, `Authorization` 미기록.
- 버전: K3s, cert-manager 차트, 프로브/더미 이미지는 실행 시점의 최신 안정판으로 **고정**하고 `k8s/VERSIONS.md`에 버전과 digest를 기록한다 **[Claude 결정]**.

## Review Focus

1. **VM 재부팅** — 재부팅 후에도 K3s, iptables 80/443 규칙, DuckDNS 타이머, Tailscale이 살아 있고 `make verify-m1`이 그대로 통과해야 한다. → Task 11에 재부팅 후 재검증 단계.
2. **공인 IP 변경** (인스턴스 stop/start 시 임시 공인 IP가 바뀜) — DuckDNS 타이머가 5분 안에 새 IP로 갱신해야 한다. → Task 5의 `m1-dns.sh`가 세 호스트의 A 레코드를 실제 공인 IP와 비교.
3. **SSH 잠김 사고** — Tailscale 경로를 확인하기 전에 공개 22를 닫으면 VM에 들어갈 수 없다. → Task 3에서 `tailscale ssh` 성공을 확인한 뒤에만 22를 닫는 가드와 OCI 콘솔 연결 예비 확인.
4. **Let's Encrypt prod 한도 소진** — staging 인증서가 Ready가 아닌데 prod로 바꾸면 실패가 반복돼 한도에 걸린다. → Task 9의 전환 스크립트가 staging Ready를 확인하지 못하면 거부.
5. **default-deny에서 kubelet 프로브 차단** — 더미 Pod의 readiness probe가 kube-router에 막히면 Pod가 Ready가 되지 않는다. → Task 8에서 프로브가 있는 더미 Pod의 Ready를 검증하고, 막히면 노드 IP 허용 규칙을 추가.

---

## File Structure

| 경로 | 책임 |
|---|---|
| `.gitignore`, `.pre-commit-config.yaml`, `.gitleaks.toml` | 비밀 미커밋 보장 |
| `config/cluster.env.example` | 필요한 변수 목록 (커밋). 실제 값은 `config/cluster.env` (gitignore) |
| `scripts/lib/assert.sh` | 검증 스크립트 공통 assertion 함수 |
| `scripts/lib/env.sh` | `config/cluster.env` 로드와 필수 변수 확인 |
| `scripts/host/bootstrap.sh` | VM 하드닝, 방화벽, Tailscale (VM에서 실행, 멱등) |
| `scripts/host/install-k3s.sh` | 고정 버전 K3s 설치 (VM에서 실행, 멱등) |
| `scripts/host/duckdns-update.sh`, `scripts/host/systemd/duckdns.{service,timer}` | IP 갱신 |
| `scripts/verify/m1-*.sh` | Task별 완료 기준 검증 |
| `scripts/cert/promote-prod.sh` | staging→prod 전환 가드 |
| `k8s/platform/traefik/` | `HelmChartConfig`, `TLSOption` |
| `k8s/platform/cert-manager/` | Helm values, `ClusterIssuer` 2개 |
| `k8s/components/traefik-middlewares/` | 네임스페이스마다 복제되는 미들웨어 (Kustomize component) |
| `k8s/base/namespaces/` | ns 5개, PSA 라벨, default-deny, N1(DNS), N5(ACME 솔버) |
| `k8s/base/dummy/` | 세 호스트용 더미 앱 (이후 실제 앱이 같은 라벨·포트를 이어받음) |
| `k8s/overlays/oci/`, `k8s/overlays/local/` | 호스트명, issuer 이름 패치 |
| `attacks/netmatrix.sh`, `attacks/lib/netmatrix.sh`, `attacks/netmatrix.expected.tsv` | NP 실측 대 기대 매트릭스 |
| `tests/scripts/` | 순수 셸 함수(파서, 비교기) 단위 테스트와 fixture |
| `tests/fixtures/psa-violation.yaml` | PSA 거부 확인용 매니페스트 |
| `Makefile` | `verify-m1`, `netmatrix`, `test-scripts` |
| `docs/runbooks/m1-*.md` | 콘솔에서 손으로 하는 작업 절차 |
| `docs/evidence/m1/`, `docs/cost/` | 캡처, 스캔 결과, 비용 화면 |
| `k8s/VERSIONS.md` | 고정한 버전과 digest |

**[Claude 결정]** 미들웨어는 `kube-system` 하나에 두고 Traefik `allowCrossNamespace`를 켜는 대신, Kustomize component로 각 앱 네임스페이스에 복제한다. 네임스페이스 경계를 넘는 참조를 허용하지 않기 위해서다.

---

### Task 1: 저장소 뼈대와 비밀 위생

M0가 아직 안 됐다면 M1에 필요한 최소한만 여기서 만든다. CI 뼈대는 M0 범위로 남긴다.

**Files:**
- Create: `.gitignore`, `.pre-commit-config.yaml`, `.gitleaks.toml`, `config/cluster.env.example`, `scripts/lib/assert.sh`, `scripts/lib/env.sh`, `Makefile`, `tests/scripts/run.sh`, `tests/scripts/test_assert.sh`

**Interfaces:**
- Produces:
  - `scripts/lib/assert.sh`: `assert_eq <expected> <actual> <msg>`, `assert_contains <haystack> <needle> <msg>`, `assert_fails <msg> -- <cmd...>`, `assert_succeeds <msg> -- <cmd...>`, `assert_fails_with <msg> [--rc n] [--match ERE] -- <cmd...>`, `assert_succeeds_strict <msg> -- <cmd...>`, `assert_summary` (실패가 하나라도 있으면 return 1 (exit가 아님), `PASS n / FAIL m` 출력). 검증 스크립트는 `assert_summary`를 마지막 명령으로 호출해야 한다.
  - `scripts/lib/env.sh`: `load_env` — `config/cluster.env`를 source하고 `PUBLIC_IP TS_IP HOST_SAFEDESK HOST_MINISHOP HOST_RELAY ACME_EMAIL K3S_VERSION` 중 비어 있는 값이 있으면 이름을 출력하고 exit 2.
  - `Makefile` 타깃: `test-scripts` (= `tests/scripts/run.sh`), `verify-m1` (Task 11에서 채움).
  - `tests/scripts/run.sh`: `tests/scripts/test_*.sh`를 모두 실행하고 하나라도 실패하면 exit 1.

- [ ] **Step 1:** `git init`, 기본 브랜치 `main`. `.gitignore`에 `config/cluster.env`, `*.kubeconfig`, `kubeconfig*`, `.env*`, `docs/evidence/**/raw/`를 넣는다.
- [ ] **Step 2: 실패하는 테스트 작성** `tests/scripts/test_assert.sh`:
  - `assert_eq a a`가 통과하고 `assert_eq a b`가 실패로 집계된다.
  - `assert_fails "x" -- false`는 통과하고 `assert_fails "x" -- true`는 실패로 집계된다.
  - 실패가 한 건이면 `assert_summary`의 종료 코드가 1이다.
  - 각 경우를 서브셸에서 돌려 종료 코드를 확인한다.
- [ ] **Step 3:** `make test-scripts` 실행 → `assert.sh` 없음으로 FAIL을 확인한다.
- [ ] **Step 4:** `assert.sh`, `env.sh`, `run.sh`, `Makefile`을 구현한다.
- [ ] **Step 5:** `make test-scripts` 실행 → `PASS`를 확인한다.
- [ ] **Step 6:** gitleaks pre-commit을 설치한다. 확인: `config/leak-test.txt`에 `DUCKDNS_TOKEN=` 뒤에 UUID 형식 값을 넣고 `git add` → `git commit`이 gitleaks로 거부된다. 확인 후 파일을 삭제한다. `.gitleaks.toml`에 DuckDNS 토큰(UUID)과 Tailscale auth key(`tskey-`) 규칙을 추가한다.
- [ ] **Step 7: 커밋** `chore: repo skeleton, assert lib, gitleaks pre-commit`

---

### Task 2: OCI VM 생성과 비용 가드레일 (수동 런북 + 호스트 검증)

**Files:**
- Create: `docs/runbooks/m1-oci-vm.md`, `scripts/verify/m1-host.sh`, `docs/cost/README.md`

**Interfaces:**
- Consumes: `assert.sh`, `env.sh`
- Produces: `config/cluster.env`의 `PUBLIC_IP` 값. VM의 `ubuntu` 사용자 SSH 키 접속.

- [ ] **Step 1: 런북 작성.** 순서대로 적는다.
  1. Free Tier 가입
  2. 홈 리전 확인
  3. 예산 1달러 알림 생성 (CG2)
  4. VCN 마법사로 공개 서브넷 생성
  5. Security List ingress는 TCP 22, 80, 443만 허용 (22는 임시)
  6. A1 Flex 2 OCPU / 12 GB, Ubuntu 24.04 aarch64, 부트 100 GB, "Always Free 사용 가능" 표시 확인
  7. 자기 SSH 공개키 등록
  8. Out of capacity가 나면 다른 AD로 재시도하고, 계속 실패하면 §19.3 대안 A (`k8s/overlays/local`, Multipass VM)로 간다
  9. OCI 콘솔의 "Cloud Shell/콘솔 연결"로 VM에 들어갈 수 있는지 예비로 확인
- [ ] **Step 2: 실패하는 검증 작성** `scripts/verify/m1-host.sh` (VM에서 실행). 다음 assertion을 둔다.
  - `uname -m` = `aarch64`
  - `nproc` = 2
  - `MemTotal`이 11 GiB 이상 12.5 GiB 이하
  - `/etc/os-release`의 `VERSION_ID` = `24.04`
  - 루트 파일시스템 크기 ≤ 100 GiB
- [ ] **Step 3:** 런북대로 VM을 만든다. VM이 생기기 전에는 `m1-host.sh`를 실행할 수 없으므로, 노트북에서 `ssh ubuntu@$PUBLIC_IP true`가 실패하는 것을 실패 확인으로 삼는다.
- [ ] **Step 4:** `scp`로 스크립트를 보낸 뒤 VM에서 `bash scripts/verify/m1-host.sh` 실행 → PASS를 확인한다.
- [ ] **Step 5:** 비용 증거 남기기. OCI 콘솔의 인스턴스 shape 화면(Always Free 표시), 예산 알림 설정, 블록 볼륨 합계 화면을 `docs/cost/2026-11-m1-*.png`로 저장한다 (CG4, CG10). 공인 IP, 이메일, 테넌시 OCID는 가린다.
- [ ] **Step 6: 커밋** `docs: OCI VM runbook, host verification, cost evidence`

---

### Task 3: 호스트 하드닝, 방화벽, Tailscale

**Files:**
- Create: `scripts/host/bootstrap.sh`, `scripts/verify/m1-ports.sh`, `scripts/verify/lib/nmap.sh`, `tests/scripts/test_nmap_parse.sh`, `tests/scripts/fixtures/nmap-*.gnmap`, `docs/runbooks/m1-tailscale.md`

**Interfaces:**
- Consumes: `assert.sh`, `env.sh` (`PUBLIC_IP`, `TS_IP`)
- Produces:
  - `scripts/verify/lib/nmap.sh`: `open_tcp_ports <gnmap_file>` — 열린 TCP 포트를 오름차순, 공백으로 구분해 출력 (예: `80 443`).
  - `scripts/verify/m1-ports.sh [--expect "80 443"]` — 노트북에서 실행하고, `nmap -Pn -p- -T4 -oG`로 `PUBLIC_IP`를 스캔해 기대값과 비교한다.
  - `bootstrap.sh` 플래그: `--close-public-ssh` (가드 통과 시에만 22를 닫음).

- [ ] **Step 1: 실패하는 테스트 작성** `tests/scripts/test_nmap_parse.sh`. fixture 3개를 둔다.
  - `22/open, 80/open, 443/open`이 있는 gnmap → `22 80 443`
  - `80/open, 443/open, 6443/filtered` → `80 443` (filtered 제외)
  - 열린 포트가 없는 경우 → 빈 문자열
- [ ] **Step 2:** `make test-scripts` → FAIL을 확인한다.
- [ ] **Step 3:** `open_tcp_ports`를 `grep`/`awk`로 gnmap의 `Ports:` 필드를 파싱해 구현한다.
- [ ] **Step 4:** `make test-scripts` → PASS를 확인한다.
- [ ] **Step 5:** 노트북에서 `scripts/verify/m1-ports.sh --expect "80 443"` 실행 → `22`가 열려 있으므로 FAIL을 확인한다. 이것이 이 Task의 실패하는 검증이다.
- [ ] **Step 6:** `bootstrap.sh`를 구현한다. 멱등이어야 하고, 두 번 실행해도 결과가 같아야 한다.
  - `unattended-upgrades` 활성화
  - `sshd_config.d/99-hardening.conf`: `PasswordAuthentication no`, `PermitRootLogin no`, `KbdInteractiveAuthentication no`
  - OCI 기본 iptables의 REJECT 규칙 앞에 TCP 80, 443 ACCEPT 삽입, `netfilter-persistent save`
  - Tailscale 설치와 `tailscale up --ssh` (auth key는 실행 시 인자로만 받고 파일에 남기지 않음)
  - `--close-public-ssh` 가드: `tailscale status`가 Online이고, 환경변수 `CONFIRM_TS_SSH=yes`가 설정되어 있을 때만 iptables에서 22를 tailscale0 인터페이스로 제한한다. 운영자가 다른 터미널에서 `tailscale ssh ubuntu@<vm>` 성공을 확인한 뒤 이 값을 설정한다.
- [ ] **Step 7:** VM에서 `sudo bash scripts/host/bootstrap.sh` → 노트북에서 `tailscale ssh ubuntu@<vm> true` 성공 → `sudo CONFIRM_TS_SSH=yes bash scripts/host/bootstrap.sh --close-public-ssh` 순서로 실행한다. 그다음 OCI Security List에서 22 규칙을 삭제한다 (런북에 기록).
- [ ] **Step 8:** `scripts/verify/m1-ports.sh --expect ""` 실행 → 열린 포트 없음으로 PASS를 확인한다. 80/443은 아직 리스너가 없어 닫혀 보인다. Task 6 이후에는 `--expect "80 443"`이 기준이 된다.
- [ ] **Step 9:** `bootstrap.sh`를 한 번 더 실행해 변경이 없는지 확인한다 (iptables 규칙 중복 없음: `iptables -S | grep -c 'dport 80'` = 1).
- [ ] **Step 10: 커밋** `feat(host): hardening, firewall 80/443, tailscale-only ssh`

---

### Task 4: K3s 설치 (Tailscale 전용 API)

**Files:**
- Create: `scripts/host/install-k3s.sh`, `scripts/verify/m1-k3s.sh`, `k8s/VERSIONS.md`, `docs/runbooks/m1-kubeconfig.md`

**Interfaces:**
- Consumes: `env.sh` (`K3S_VERSION`, `TS_IP`, `PUBLIC_IP`)
- Produces: 노트북의 `~/.kube/secure-ax.kubeconfig` (server 주소는 `https://$TS_IP:6443`). 이후 모든 Task의 `kubectl`은 `KUBECONFIG=~/.kube/secure-ax.kubeconfig`로 실행한다.

- [ ] **Step 1: 실패하는 검증 작성** `scripts/verify/m1-k3s.sh` (노트북에서 실행):
  - `kubectl get nodes` → 노드 1개 `Ready`
  - `kubectl version -o json`의 서버 `gitVersion`이 `K3S_VERSION`과 같다
  - VM에서 `ssh ... sudo k3s secrets-encrypt status` 출력에 `Encryption Status: Enabled`
  - `curl -sk --max-time 5 https://$PUBLIC_IP:6443` 실패 (공개 경로 차단)
  - `curl -sk --max-time 5 https://$TS_IP:6443/version` 결과가 HTTP 401 또는 200 (Tailscale 경로 응답)
  - `kubectl -n kube-system get deploy traefik metrics-server coredns local-path-provisioner` 모두 Available
  - VM의 `/etc/rancher/k3s/k3s.yaml` 권한이 `600`
- [ ] **Step 2:** 실행 → `kubectl` 연결 실패로 FAIL을 확인한다.
- [ ] **Step 3:** `install-k3s.sh`를 구현한다. `curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - server --secrets-encryption --write-kubeconfig-mode 600 --tls-san $TS_IP --node-external-ip $PUBLIC_IP` 형태로 설치한다.
  - 이미 같은 버전이 설치되어 있으면 건너뛴다.
  - 설치 스크립트는 받은 뒤 sha256을 출력해서 런북에 기록한다.
  - 6443은 Task 3의 iptables가 공개 인터페이스에서 이미 막고 있으므로 별도 규칙이 필요 없다. 이 사실을 검증으로 확인한다.
- [ ] **Step 4:** 런북대로 kubeconfig를 노트북으로 가져와 server 주소를 `TS_IP`로 바꾸고 `chmod 600`한다.
- [ ] **Step 5:** `scripts/verify/m1-k3s.sh` → PASS를 확인한다. `k8s/VERSIONS.md`에 K3s 버전과 함께 설치된 Traefik 차트 버전(`kubectl -n kube-system get helmchart traefik -o yaml`)을 기록한다.
- [ ] **Step 6:** 기준선을 측정한다. VM에서 `free -m`과 `kubectl top node`를 실행해 결과를 `docs/evidence/m1/resource-baseline.md`에 남기고, 기획서 §15.1의 "OS + K3s" 행을 실측값으로 갱신한다.
- [ ] **Step 7: 커밋** `feat(k3s): pinned install with secrets-encryption, tailscale-only API`

---

### Task 5: DuckDNS 호스트 3개와 IP 자동 갱신

**Files:**
- Create: `scripts/host/duckdns-update.sh`, `scripts/host/systemd/duckdns.service`, `scripts/host/systemd/duckdns.timer`, `scripts/verify/m1-dns.sh`, `docs/runbooks/m1-duckdns.md`

**Interfaces:**
- Consumes: `env.sh` (`HOST_SAFEDESK HOST_MINISHOP HOST_RELAY PUBLIC_IP`)
- Produces: 세 FQDN이 공인 IP를 가리킴. VM의 `/etc/duckdns/token` (root:root 600, 저장소 밖).

- [ ] **Step 1: 실패하는 검증 작성** `scripts/verify/m1-dns.sh`. 세 호스트 각각에 대해 `dig +short A <host> @1.1.1.1`이 VM의 현재 공인 IP와 같은지 확인한다. 공인 IP는 VM에서 `curl -s https://ifconfig.me`로 얻는다.
- [ ] **Step 2:** 실행 → FAIL을 확인한다 (레코드 없음).
- [ ] **Step 3:** 런북: DuckDNS 로그인, 서브도메인 3개 등록, 무료 계정 서브도메인 한도를 확인해서 부록 A 항목을 갱신한다.
- [ ] **Step 4:** `duckdns-update.sh`를 구현한다.
  - 토큰은 `/etc/duckdns/token`에서 읽는다.
  - `https://www.duckdns.org/update?domains=<3개 쉼표 구분>&token=...&ip=` 호출의 응답이 `OK`가 아니면 exit 1.
  - 토큰이나 URL을 로그에 출력하지 않는다.
  - timer는 부팅 2분 후와 5분마다 실행하도록 설정한다.
- [ ] **Step 5:** VM에 설치하고 `systemctl enable --now duckdns.timer` → `m1-dns.sh` PASS를 확인한다.
- [ ] **Step 6:** `journalctl -u duckdns`에 토큰 문자열이 없는지 확인한다 (`grep -c <토큰 앞 8자>` = 0).
- [ ] **Step 7: 커밋** `feat(host): duckdns updater for three hosts`

---

### Task 6: Traefik 설정 — 클라이언트 IP 보존, TLS 1.2, 접근 로그 위생

**Files:**
- Create: `k8s/platform/traefik/helmchartconfig.yaml`, `k8s/platform/traefik/tlsoption.yaml`, `k8s/platform/traefik/kustomization.yaml`, `scripts/verify/m1-traefik.sh`

**Interfaces:**
- Consumes: kubeconfig (Task 4)
- Produces: Traefik Service `externalTrafficPolicy: Local`. `TLSOption` `default` (ns `kube-system`, `minVersion: VersionTLS12`). 접근 로그 JSON 형식.

- [ ] **Step 1: 실패하는 검증 작성** `scripts/verify/m1-traefik.sh`:
  - `kubectl -n kube-system get svc traefik -o jsonpath='{.spec.externalTrafficPolicy}'` = `Local`
  - Traefik 컨테이너 args에 `--api.dashboard=true`가 없거나, 대시보드 라우트가 없음 (`curl -sk https://$HOST_SAFEDESK/dashboard/` ≠ 200)
  - `tlsoption default`의 `minVersion` = `VersionTLS12`
  - `curl -sk --tls-max 1.1 https://$HOST_SAFEDESK` 실패
  - 노트북에서 요청을 보낸 뒤 Traefik 로그 최근 줄의 `ClientHost`가 노트북의 공인 IP와 같음
  - 로그에 `request_Cookie`, `request_Authorization` 키가 없음, `RequestPath`에 `?` 없음 (`curl https://$HOST_SAFEDESK/?probe=secret123` 후 `secret123` grep 결과 0)
  - `m1-ports.sh --expect "80 443"` PASS
- [ ] **Step 2:** 실행 → FAIL을 확인한다.
- [ ] **Step 3:** `helmchartconfig.yaml`(name `traefik`, ns `kube-system`)을 작성한다. `valuesContent`에 다음을 넣는다. 정확한 키 이름은 Task 4에서 기록한 차트 버전의 `values.yaml`에서 확인한다 (부록 A 항목).
  - `service.spec.externalTrafficPolicy: Local`
  - 대시보드 비활성
  - 접근 로그 JSON, `fields.headers.defaultmode: drop`
  - 쿼리스트링을 남기지 않는 설정. 쿼리만 잘라내는 옵션이 없으면 `fields.names`에서 `RequestPath`를 `drop`하고 `RouterName`과 `RequestMethod`, `DownstreamStatus`만 남긴다. 이 경우 검증 항목 "RequestPath에 `?` 없음"은 "RequestPath 필드 없음"으로 바꾼다.

  적용은 VM의 `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml`로 복사해서 한다 (K3s 자동 배포 경로). 같은 파일을 저장소에도 둔다.
- [ ] **Step 4:** `tlsoption.yaml`을 `kubectl apply -k k8s/platform/traefik`로 적용한다 (`HelmChartConfig` 제외. 이 kustomization에는 TLSOption만 넣는다).
- [ ] **Step 5:** 클라이언트 IP, TLS, 로그 항목은 HTTPS 라우트가 생긴 뒤(Task 9) 통과할 수 있다. 이 시점에는 `externalTrafficPolicy`, 대시보드, TLSOption 객체, 포트 항목만 PASS인지 확인하고, 나머지는 Task 9 Step 7에서 다시 돌린다.
- [ ] **Step 6: 커밋** `feat(ingress): traefik helmchartconfig, TLS1.2 floor, log hygiene`

---

### Task 7: cert-manager와 ClusterIssuer

**Files:**
- Create: `k8s/platform/cert-manager/values.yaml`, `k8s/platform/cert-manager/clusterissuers.yaml`, `k8s/platform/cert-manager/kustomization.yaml`, `scripts/verify/m1-certmanager.sh`, `docs/runbooks/m1-cert-manager.md`

**Interfaces:**
- Consumes: kubeconfig, `env.sh` (`ACME_EMAIL`)
- Produces: `ClusterIssuer` 이름 `letsencrypt-staging`, `letsencrypt-prod`. 둘 다 HTTP-01, solver ingress class `traefik`. 이 이름은 Task 9의 Ingress 어노테이션 `cert-manager.io/cluster-issuer`가 쓴다.

- [ ] **Step 1: 실패하는 검증 작성** `m1-certmanager.sh`:
  - ns `cert-manager`의 deploy 3개(`cert-manager`, `cert-manager-webhook`, `cert-manager-cainjector`)가 Available
  - 이미지가 arm64 노드에서 실행 중 (Pod Running이면 충족)
  - `kubectl get clusterissuer letsencrypt-staging letsencrypt-prod -o jsonpath='{..status.conditions[?(@.type=="Ready")].status}'` = `True True`
- [ ] **Step 2:** 실행 → FAIL을 확인한다.
- [ ] **Step 3:** 런북: `helm repo add jetstack https://charts.jetstack.io`. 버전은 고정해서 `k8s/VERSIONS.md`에 기록하고, `helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --version <고정> -f values.yaml`로 설치한다.
  - `values.yaml`: `crds.enabled: true`, 컴포넌트별 resources를 §15.1 합계(requests 150Mi, limits 300Mi)에 맞게 나눈다.
- [ ] **Step 4:** `clusterissuers.yaml`을 작성한다. ACME 이메일은 저장소에 넣지 않는다. `kustomization.yaml`의 `replacements`나 `envsubst`로 `config/cluster.env`에서 주입하고, 렌더링 결과는 커밋하지 않는다 **[Claude 결정]**.
- [ ] **Step 5:** 적용 → `m1-certmanager.sh` PASS를 확인한다.
- [ ] **Step 6: 커밋** `feat(tls): cert-manager pinned, staging/prod ClusterIssuers`

---

### Task 8: 네임스페이스 5개 — PSA restricted, default-deny, DNS(N1), ACME 솔버(N5)

**Files:**
- Create: `k8s/base/namespaces/kustomization.yaml`, `namespaces.yaml`, `netpol-default-deny.yaml`, `netpol-allow-dns.yaml`, `netpol-allow-acme-solver.yaml`, `tests/fixtures/psa-violation.yaml`, `scripts/verify/m1-psa.sh`

**Interfaces:**
- Produces:
  - 네임스페이스 `pii-relay safedesk minishop openbao audit-anchor`. 각각 라벨 `pod-security.kubernetes.io/enforce: restricted`, `pod-security.kubernetes.io/enforce-version: latest`, `audit`과 `warn`도 `restricted`.
  - 각 ns의 `NetworkPolicy`:
    - `default-deny` (`podSelector: {}`, `policyTypes: [Ingress, Egress]`)
    - `allow-dns-egress` (N1: `kube-system`의 `k8s-app: kube-dns` Pod로 53 UDP/TCP)
    - `allow-acme-solver-ingress` (N5: `kube-system`의 `app.kubernetes.io/name: traefik` → `acme.cert-manager.io/http01-solver: "true"` Pod, 8089)
  - 이 정책 이름들은 이후 마일스톤에서 고치지 않고 허용 정책만 추가한다.

- [ ] **Step 1: 실패하는 검증 작성** `scripts/verify/m1-psa.sh`. 5개 ns 각각에 대해 다음을 확인한다.
  - `kubectl apply --dry-run=server -n <ns> -f tests/fixtures/psa-violation.yaml`이 실패하고 출력에 `violates PodSecurity "restricted` 포함
  - `kubectl get netpol -n <ns>`에 정책 3개 존재

  `psa-violation.yaml`은 `privileged: true`, `hostNetwork: true`, root 실행을 넣은 Pod다.
- [ ] **Step 2:** 실행 → FAIL을 확인한다 (ns 없음).
- [ ] **Step 3:** 매니페스트를 작성하고 `kubectl apply -k k8s/base/namespaces`로 적용한다. ACME 솔버 Pod 라벨은 Task 7에서 고정한 cert-manager 버전의 실제 솔버 Pod 라벨을 확인해서 쓴다.
- [ ] **Step 4:** `m1-psa.sh` → PASS를 확인한다.
- [ ] **Step 5: kubelet 프로브 확인 (Review Focus 5).**
  1. `safedesk` ns에 restricted를 지키고 readiness probe가 있는 임시 Pod를 띄운다 (Task 9의 더미 이미지와 같은 것).
  2. 60초 안에 `Ready=True`가 되는지 확인한다.
  3. 안 되면 `allow-kubelet-probes` 정책(노드 IP/32 → 해당 포트 ingress, `ipBlock`)을 5개 ns 모두에 추가하고 결과를 부록 A에 기록한다.
  4. 결과가 어느 쪽이든 `docs/evidence/m1/kubelet-probe.md`에 남긴다.
- [ ] **Step 6: 커밋** `feat(k8s): five namespaces with PSA restricted and default-deny NP`

---

### Task 9: 더미 앱 3개, 미들웨어, HTTPS (staging → prod)

더미는 이후 실제 앱이 같은 라벨과 포트를 이어받는 자리다. 그래서 N2, N3, N4 규칙을 지금 실제 이름으로 만든다 **[Claude 결정]**. 기획서 M3/M4/M6에 있는 같은 규칙은 "이미 있음, 대상만 교체"가 된다.

**Files:**
- Create: `k8s/components/traefik-middlewares/{kustomization.yaml, redirect.yaml, sec-headers.yaml}`, `k8s/base/dummy/{kustomization.yaml, deploy.yaml, service.yaml, ingress.yaml, netpol-allow-traefik.yaml}`, `k8s/overlays/oci/kustomization.yaml`, `k8s/overlays/local/kustomization.yaml`, `scripts/cert/promote-prod.sh`, `scripts/verify/m1-tls.sh`

**Interfaces:**
- Consumes: `ClusterIssuer` 이름(Task 7), 네임스페이스와 정책(Task 8), `HOST_*`
- Produces:

  | ns | Deployment/Service 이름 = `app.kubernetes.io/name` | 컨테이너 포트 | 호스트 | NP |
  |---|---|---|---|---|
  | `safedesk` | `safedesk-app` | 8000 | `HOST_SAFEDESK` | N2 |
  | `minishop` | `minishop-app` | 8000 | `HOST_MINISHOP` | N3 |
  | `pii-relay` | `relay-reveal` | 8001 | `HOST_RELAY` | N4 |

  - 미들웨어 이름(각 ns 안): `https-redirect`, `sec-headers`. Ingress 어노테이션 값은 `<ns>-https-redirect@kubernetescrd,<ns>-sec-headers@kubernetescrd`.
  - TLS Secret 이름: `<app>-tls`.
  - `scripts/cert/promote-prod.sh` — 세 `Certificate`가 모두 staging 발급자로 `Ready=True`일 때만 overlay의 issuer를 `letsencrypt-prod`로 바꿔 적용한다. 아니면 exit 1과 함께 Ready가 아닌 인증서 이름을 출력한다.

- [ ] **Step 1: 실패하는 검증 작성** `scripts/verify/m1-tls.sh [--issuer staging|prod]`. 세 호스트 각각에 대해 다음을 확인한다.
  - `curl -s -o /dev/null -w '%{http_code}' http://<host>/` = `301`, `Location`이 `https://`로 시작
  - HTTPS 200 (`--issuer staging`이면 `-k`, `prod`이면 인증서 검증 포함)
  - 응답 헤더에 `strict-transport-security: max-age=31536000; includeSubDomains`, `x-content-type-options: nosniff`, `referrer-policy: no-referrer`, `x-frame-options: DENY`, `content-security-policy`에 `frame-ancestors 'none'` 포함, `server` 헤더 없음
  - `--issuer prod`일 때 `openssl s_client`로 본 발급자에 `Let's Encrypt` 포함, `(STAGING)` 미포함
- [ ] **Step 2:** `m1-tls.sh --issuer staging` → FAIL을 확인한다.
- [ ] **Step 3:** 더미 Deployment를 작성한다.
  - 이미지: arm64, non-root로 동작하는 HTTP 에코 서버(예: `traefik/whoami`, `--port` 인자 지원). 실제 선택한 이미지의 digest를 `k8s/VERSIONS.md`에 기록한다.
  - securityContext는 §15 전체를 적용한다: `runAsNonRoot`, 고정 UID, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true`
  - `automountServiceAccountToken: false`, resources `requests 16Mi/10m, limits 32Mi/100m`, readinessProbe HTTP GET `/`
- [ ] **Step 4:** 미들웨어 component를 작성한다. `sec-headers`의 CSP `form-action`에는 overlay에서 `https://$HOST_RELAY`를 주입한다. `Server` 헤더 제거는 `customResponseHeaders: {Server: ""}`로 한다. 세 ns overlay에서 이 component를 쓴다.
- [ ] **Step 5:** `netpol-allow-traefik.yaml`(N2/N3/N4)을 작성한다. `kube-system`의 `app.kubernetes.io/name: traefik` → 위 표의 Pod와 포트만 허용하고, relay-reveal은 8001만 허용한다.
- [ ] **Step 6:** `kubectl apply -k k8s/overlays/oci` (issuer는 `letsencrypt-staging`) → 인증서 Ready 대기 → `m1-tls.sh --issuer staging` PASS를 확인한다.
- [ ] **Step 7:** `m1-traefik.sh`를 다시 실행 → 전부 PASS인지 확인한다 (Task 6 Step 5에서 남겨둔 항목).
- [ ] **Step 8 (Review Focus 4):** 세 Certificate 중 하나를 `kubectl delete certificate`로 지운 상태에서 `promote-prod.sh`가 exit 1로 거부되는지 확인한다. 그다음 `kubectl apply -k k8s/overlays/oci`로 복구하고 다시 Ready가 되기를 기다린다.
- [ ] **Step 9:** `scripts/cert/promote-prod.sh` 실행 → `m1-tls.sh --issuer prod` PASS를 확인한다.
- [ ] **Step 10:** `testssl.sh --quiet --severity MEDIUM https://$HOST_RELAY` 결과를 `docs/evidence/m1/testssl-relay.txt`에 저장한다 (선택, 있으면 TLS1.0/1.1 미지원 확인).
- [ ] **Step 11: 커밋** `feat(ingress): dummy apps on three hosts with HTTPS, security headers, N2-N4`

---

### Task 10: `attacks/netmatrix.sh` 뼈대

**Files:**
- Create: `attacks/lib/netmatrix.sh`, `attacks/netmatrix.sh`, `attacks/netmatrix.expected.tsv`, `attacks/probe-pod.yaml.tmpl`, `tests/scripts/test_netmatrix_compare.sh`, `tests/scripts/fixtures/netmatrix-{expected,actual-ok,actual-bad}.tsv`

**Interfaces:**
- Produces:
  - 기대 매트릭스 TSV 열: `rule_id  src_ns  src_app  dst_host  port  proto  expect` (`expect` ∈ `allow|deny`, `proto` ∈ `tcp|udp`, `#` 주석 허용). 이후 마일스톤은 이 파일에 행만 추가한다.
  - 실측 TSV 열: `rule_id  result` (`result` ∈ `allow|deny`).
  - `compare_matrix <expected.tsv> <actual.tsv>` — 표(`rule_id src→dst:port expect actual OK|MISMATCH`)를 stdout으로 출력하고, 불일치 건수를 종료 코드로 반환한다. 실측에 없는 `rule_id`는 `MISSING`으로 불일치에 센다.
  - `attacks/netmatrix.sh [--keep-pods]`:
    1. 기대 파일의 고유한 `(src_ns, src_app)`마다 프로브 Pod를 하나 띄운다. 이 Pod는 **출발지 앱과 같은 라벨**을 달기 때문에 그 앱이 받는 정책을 그대로 받는다. kube-system/traefik 출발은 라벨 `app.kubernetes.io/name: traefik`.
    2. 각 행을 `nc -z -w 2`(tcp) 또는 `nslookup`(DNS 행)으로 시험한다.
    3. `compare_matrix`로 결과를 내고, `docs/evidence/m1/netmatrix-<날짜>.txt`에 저장한다.
    4. 끝나면 프로브 Pod를 지운다.
  - 프로브 Pod는 PSA restricted를 지킨다 (non-root, drop ALL, seccomp, 읽기 전용 루트, `automountServiceAccountToken: false`). 이미지는 arm64 busybox 계열이고 digest를 고정한다.

- [ ] **Step 1: 실패하는 테스트 작성** `test_netmatrix_compare.sh`:
  - `actual-ok` → 종료 코드 0, 모든 줄 `OK`
  - `actual-bad`(deny 기대인데 allow 하나, 행 하나 누락) → 종료 코드 2, `MISMATCH` 1줄과 `MISSING` 1줄
  - 주석과 빈 줄은 무시
- [ ] **Step 2:** `make test-scripts` → FAIL을 확인한다.
- [ ] **Step 3:** `attacks/lib/netmatrix.sh`의 `compare_matrix`를 구현한다 (awk 조인).
- [ ] **Step 4:** `make test-scripts` → PASS를 확인한다.
- [ ] **Step 5:** `attacks/netmatrix.expected.tsv`에 M1 행을 작성한다. 규칙 ID는 기획서 §10을 따르고, M1 전용 음성 검사는 `M1-*`로 붙인다.

  | rule_id | 내용 | expect |
  |---|---|---|
  | N1-<ns> ×5 | 각 ns의 프로브 → `kube-dns.kube-system.svc.cluster.local` 53/udp | allow |
  | N2, N3, N4 | traefik → `safedesk-app.safedesk.svc:8000`, `minishop-app.minishop.svc:8000`, `relay-reveal.pii-relay.svc:8001` | allow |
  | M1-X1 | safedesk-app → `minishop-app.minishop.svc:8000` | deny |
  | M1-X2 | minishop-app → `relay-reveal.pii-relay.svc:8001` | deny |
  | M1-X3 | safedesk-app → `1.1.1.1:443` | deny (외부 egress) |
  | M1-X4 | safedesk-app → `<노드 IP>:6443` | deny (N17은 relay·openbao만) |
  | M1-X5 | safedesk-app → `<노드 IP>:10250` | deny |
  | M1-X6 | `openbao` ns 프로브 → `1.1.1.1:443` | deny |
  | M1-X7 | `audit-anchor` ns 프로브 → `1.1.1.1:443` | deny (N20은 M4에서 추가) |
  | M1-X8 | traefik → `relay-reveal.pii-relay.svc:8002` | deny (8002는 내부 전용) |

  `<노드 IP>`는 실행 시 `kubectl get node -o jsonpath`로 치환한다.
- [ ] **Step 6:** `bash attacks/netmatrix.sh` 실행 → 모든 행 `OK`, 종료 코드 0을 확인한다. 만약 처음 실행에서 이미 통과한다면, 일부러 `default-deny`를 `safedesk`에서 지운 상태로 한 번 돌려 M1-X1/X3가 `MISMATCH`로 잡히는지 확인하고 복구한다. 검사기가 실제로 잡아낸다는 증거다. 그 출력을 `docs/evidence/m1/netmatrix-negative-control.txt`로 남긴다.
- [ ] **Step 7:** `Makefile`에 `netmatrix: ; bash attacks/netmatrix.sh`를 추가한다.
- [ ] **Step 8: 커밋** `feat(attacks): netmatrix probe and comparator with M1 expectations`

---

### Task 11: M1 완료 검증, 재부팅 내구성, 문서 갱신

**Files:**
- Modify: `Makefile` (`verify-m1`), `docs/2026-11-11-secure-ax-k3s-design.md` (§15.1 OS+K3s 실측, 부록 A의 M1 확인 항목), `k8s/VERSIONS.md`
- Create: `docs/evidence/m1/README.md`

**Interfaces:**
- Consumes: Task 2~10의 검증 스크립트 전부
- Produces: `make verify-m1` — 노트북에서 실행하면 다음을 순서대로 돌리고 하나라도 실패하면 exit 1.
  - `m1-k3s.sh`
  - `m1-dns.sh` (VM에서 원격 실행)
  - `m1-ports.sh --expect "80 443"`
  - `m1-traefik.sh`
  - `m1-certmanager.sh`
  - `m1-psa.sh`
  - `m1-tls.sh --issuer prod`
  - `netmatrix`

- [ ] **Step 1:** `verify-m1` 타깃을 작성하고 실행 → 전부 PASS를 확인한다. 출력 전체를 `docs/evidence/m1/verify-<날짜>.txt`에 저장한다 (공인 IP는 `x.x.x.x`로 치환한 뒤 커밋).
- [ ] **Step 2 (Review Focus 1):** VM을 `sudo reboot`하고 5분 기다린 뒤 `make verify-m1` → 전부 PASS를 확인한다. 실패 항목이 있으면 원인(서비스 enable 누락, iptables 미저장 등)을 고치고 재부팅부터 다시 한다.
- [ ] **Step 3 (Review Focus 2):** OCI 콘솔에서 인스턴스를 stop/start해서 임시 공인 IP가 바뀌면, `config/cluster.env`의 `PUBLIC_IP`를 갱신하고 10분 안에 `make verify-m1`이 PASS하는지 확인한다. IP가 바뀌지 않았다면 그렇다고 기록한다.
- [ ] **Step 4:** 비용 점검: OCI 비용 분석 화면을 캡처하고 (0원), 볼륨 합계가 200 GB 이하인지 `docs/cost/`에 남긴다 (CG4, CG10).
- [ ] **Step 5:** 기획서를 갱신한다.
  - §15.1 "OS + K3s" 행과 Traefik, cert-manager 실측값
  - 부록 A의 "kube-router NP와 kubelet 프로브", "Traefik 차트 값 키", "DuckDNS 서브도메인 한도"를 확인됨으로 변경
  - §20 M1 행 옆에 완료일
- [ ] **Step 6:** `docs/evidence/m1/README.md`에 완료 기준별 증거 파일 링크 표를 만든다. 기준은 세 호스트 HTTPS 200, HTTP 301, 80/443만 개방, 6443은 Tailscale 전용, PSA 거부, netmatrix다.
- [ ] **Step 7: 커밋** `docs: M1 evidence, measured baseline, appendix A updates`

---

## Self-Review 결과

- **Spec 대조:** §20 M1 행의 항목을 아래 Task에 대응시켰다.

  | M1 항목 | Task |
  |---|---|
  | VM | 2 |
  | Tailscale | 3 |
  | K3s, secrets-encryption | 4 |
  | DuckDNS 3개 | 5 |
  | Traefik HelmChartConfig, `externalTrafficPolicy: Local` | 6 |
  | cert-manager | 7 |
  | 5개 ns, PSA, default-deny, N1, N5 | 8 |
  | 기본 미들웨어, 더미 HTTPS | 9 |
  | netmatrix 뼈대 | 10 |
  | kubelet 프로브 확인 | 8 Step 5 |
  | 완료 기준: HTTPS 200, HTTP 301 | 9, 11 |
  | 완료 기준: 80/443만 개방 | 3, 6, 11 |
  | 완료 기준: 6443은 Tailscale에서만 | 4 |
  | 완료 기준: PSA 거부 | 8 |
  | 완료 기준: netmatrix | 10 |

  §11.3의 rate limit·body-limit·`sec-headers-strict`·console-ipallow는 기획서 M7("rate limit·TLSOption 최종 조정")과 실제 라우트가 생기는 M3/M4 범위라 넣지 않았다. M1 행은 "기본 미들웨어(리다이렉트, 보안 헤더)"만 요구한다.
- **범위 밖:** OpenBao 설치와 언실(M2), CI 파이프라인(M0/M8), 앱 코드(M2 이후).
- **기획서와 달라진 점:** N2/N3/N4를 M1에서 미리 만든다 (Task 9의 Claude 결정). 기획서의 M3/M4/M6 행에서 해당 규칙은 "이미 존재"로 읽으면 된다.
