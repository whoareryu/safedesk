# M1 runbook: create the Lima VM (manual, on the Mac)

Local-first target (`TARGET=local`). The VM definition is `infra/lima/secure-ax.yaml`.
The instance name comes from `LIMA_INSTANCE` in the gitignored `config/cluster.env`
(example below uses `secure-ax`).

WARNING: the local VM has no host firewall (Q13). Inbound exposure is blocked only by
`networks: []` and the 6443-only `portForwards` list in the definition. Do not edit
either without re-running `scripts/verify/m1-lima.sh`.

## 1. Install and record versions

```sh
brew install lima jq shellcheck
limactl --version
```

Record the `limactl` version in `k8s/VERSIONS.md`. Lima 2.x is required.

## 2. Check the definition before creating anything

```sh
limactl tmpl validate infra/lima/secure-ax.yaml
t=$(mktemp -d)
limactl tmpl copy --embed-all infra/lima/secure-ax.yaml "$t/merged.yaml"
limactl tmpl yq "$t/merged.yaml" '{"mounts": (.mounts // []), "networks": (.networks // [])} | @json'
rm -rf "$t"
```

Expected output, exactly: `{"mounts":[],"networks":[]}`.
Anything else (any entry under `mounts` or `networks`) means stop: a base template
re-added the Mac home mount or a VM network (see `k8s/VERSIONS.md`). Do not grep the
merged file for `location:` — the image list also uses `location:` for image URLs.

## 3. Create and start

```sh
export LIMA_INSTANCE=secure-ax        # same value as in config/cluster.env
limactl create --name="$LIMA_INSTANCE" infra/lima/secure-ax.yaml
limactl start "$LIMA_INSTANCE"
```

## 4. Record the image

After the first `limactl create`, record in `k8s/VERSIONS.md` the Ubuntu image URL
and digest Lima actually used (from `limactl list --json "$LIMA_INSTANCE"` or the
create log). Replace the placeholder row.

## 5. Verify

```sh
scripts/verify/m1-lima.sh            # instance config, on the Mac
```

Then run `m1-host.sh` inside the VM through `vm_run` (`scripts/verify/lib/remote.sh`),
from the repo root, both as the default user and as root:

```sh
bash -c '. scripts/lib/env.sh; load_env; . scripts/verify/lib/remote.sh; vm_run scripts/verify/m1-host.sh && vm_run --root scripts/verify/m1-host.sh'
```

The second call also confirms passwordless sudo (`limactl shell "$LIMA_INSTANCE" -- sudo -n true`).

## Notes

- The repo is not mounted in the VM; `vm_run` copies `scripts/lib/`, `scripts/verify/lib/`, the top-level files of `scripts/host/` (not `scripts/host/systemd/`) and the target script to a per-run `/tmp/secure-ax.XXXXXX` and removes it afterwards.
- Never add `networks`, `mounts` or portForward rules to "fix" connectivity. Ask first.

## LAN 스캔 (S1 대체 증거, 수동, Mac에서)

Mac의 LAN IP에서 VM이 포트를 늘리지 않는지, VM 꺼짐/켜짐 두 번의 `nmap` 결과로 비교한다. 호스트 방화벽이 없으므로 이 증거와 `m1-exposure.sh`가 `networks: []`·포워드 규칙의 효과를 보여 준다. 이 절은 스캔을 **수동으로** 한 번 하는 절차이고, 검증 스크립트는 스캔 자체를 실행하지 않는다.

기본 경로는 Mac의 Docker 컨테이너(`make lan-scan`)다. 런타임은 **Docker Desktop**(`docker --context desktop-linux`)으로 고정되어 있다. 현재 Docker 컨텍스트가 Colima여도 쓰지 않으며, Docker Desktop이 아닌 런타임은 거부한다. 한계: 이 스캔은 Mac 안(Docker Desktop VM)에서 출발하므로 실제 LAN 경로를 지나지 않고 macOS 애플리케이션 방화벽도 거치지 않는다. 그래서 증거 머리에 `scanner: docker`, `docker-context:`, `docker-runtime:`, 한계 문장이 자동으로 들어가고, `m1-lan-scan.sh`는 이것들이 없으면 FAIL시킨다. 같은 LAN의 다른 실제 기기(다른 노트북의 nmap, 안드로이드 Termux의 nmap)에서 같은 명령으로 스캔할 수 있게 되면 그쪽이 더 강한 증거다. 그 경우 3~4의 스캔 명령만 아래 "다른 기기" 메모대로 바꾼다.

사전 준비:
- Docker Desktop 실행 (`open -a Docker`; `docker --context desktop-linux info`가 성공해야 한다).
- **Colima와 다른 Lima 인스턴스, `ssh -L`/`-D` 터널은 스캔 시간 내내 꺼 둔다** (`colima status`가 "not running"). 이들이 Mac의 `*:53`, `*:10250` 같은 비루프백 포트를 잡고 있으면 그 포트에서 VM이 무엇을 여는지 스캔이 볼 수 없고(사각지대), 명시 음성 검사(10250)가 VM과 무관하게 FAIL한다.
- Mac이 집 등 신뢰하는 LAN에 연결, 작업 디렉터리는 저장소 루트.

```sh
LAN_IP="$(ipconfig getifaddr "$(route -n get default | awk '/interface:/ {print $2}')")"   # 값은 문서에 쓰지 않는다
mkdir -p docs/evidence/m1/raw      # raw/ 는 .gitignore 대상 (치환 전 원본)
make lan-scan-guard                # 읽기 전용 사전 점검: limactl/ssh 비루프백 리스너가 있으면 FAIL (포트만 출력)
make lan-scan OUT=docs/evidence/m1/raw/dry.gnmap LAN_SCAN_ARGS=--dry-run   # 모든 점검만, 스캔·파일 쓰기 없음
```

스캔 대상은 항상 위 `LAN_IP`(Mac의 실제 LAN 주소)다. `host.docker.internal`이나 Docker 게이트웨이 주소는 쓰지 않는다 (`lan-scan-docker.sh`가 호스트 이름, 루프백/링크로컬 주소, 그리고 `ifconfig`에 없는 주소를 거부한다).

1. **대조 리스너**: 별도 터미널에서 **빈 임시 디렉터리**를 서빙한다 (저장소 루트를 서빙하면 gitignore된 `config/cluster.env` 등이 LAN에 열린다):
   ```sh
   python3 -m http.server 18090 --bind "$LAN_IP" --directory "$(mktemp -d)"
   ```
   스캐너가 Mac의 열린 포트를 실제로 본다는 양성 대조이며, 두 스캔 모두에서 18090이 열림으로 나와야 한다.
2. **방화벽 상태** (sudo 불필요): `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate`.
   - `disabled`: 건너뛴다. 기록은 `firewall-state: disabled`, `firewall-allowance: no`.
   - `enabled`인데 스캔에서 18090이 막히면 (MANUAL, sudo 필요, 스캔하는 동안만) python을 허용한다. 방화벽은 **심볼릭 링크를 따라간 실제 실행 파일**을 기록하므로 그 경로를 쓴다: `PY_REAL="$(python3 -c 'import os,sys;print(os.path.realpath(sys.executable))')"` → `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$PY_REAL"` 후 `sudo ... --unblockapp "$PY_REAL"`. 3~4에서 `LAN_SCAN_ARGS="--firewall-allowance yes --python-path $(command -v python3)"`를 넘기면 머리에 `firewall-python:`(링크 경로)와 `firewall-python-resolved:`(실제 경로)가 함께 기록되고, `m1-lan-scan.sh`가 둘 다 `--listapps`에서 빠졌는지 본다.
3. **VM 끄고 스캔**:
   ```sh
   limactl stop "$LIMA_INSTANCE"
   make lan-scan OUT=docs/evidence/m1/raw/lan-scan-base-vm-off.gnmap
   ```
   `lan-scan-docker.sh`는 스캔 전에 사전 점검(`make lan-scan-guard`와 같음)을 다시 돌린다. 헤더(`scanner: docker`, `control-port: 18090`, `firewall-state`, `firewall-allowance`, `docker-context`, `docker-runtime`, `nmap-image`, 한계 문장)는 자동으로 들어간다. 방화벽 상태는 자동 감지된다. **결과에서 18090이 `open`이 아니면 (예: `filtered`) 스캔이 무효다.** 기록하지 말고 멈춰서 대조 리스너와 방화벽을 점검한 뒤 다시 한다. 확인: `grep -F '18090/open' docs/evidence/m1/raw/lan-scan-base-vm-off.gnmap`.
4. **VM 켜고 스캔**:
   ```sh
   limactl start "$LIMA_INSTANCE"
   make lan-scan OUT=docs/evidence/m1/raw/lan-scan-base-vm-on.gnmap
   ```
   같은 방식으로 18090 확인. 3과 4는 연달아 한다 (그 사이 다른 앱의 임의 포트가 바뀌면 비교가 FAIL할 수 있다).
5. **치환·저장**: 원본을 복사해 `scrub_evidence`와 `check-evidence-clean`을 거친 것만 `docs/evidence/m1/`에 둔다. `LAN_IP`를 export해야 `Host:` 줄의 주소가 `<LAN_IP>`로 바뀐다 (`m1-lan-scan.sh`는 모든 `Host:` 줄이 `Host: <LAN_IP> ()`인지 확인한다).
   ```sh
   export LAN_IP
   for s in off on; do
     cp docs/evidence/m1/raw/lan-scan-base-vm-$s.gnmap docs/evidence/m1/lan-scan-base-vm-$s.gnmap
     bash -c '. scripts/verify/lib/scrub.sh; scrub_evidence "$1"' _ docs/evidence/m1/lan-scan-base-vm-$s.gnmap
   done
   scripts/verify/check-evidence-clean.sh docs/evidence/m1/lan-scan-base-vm-*.gnmap
   ```
   원본(`raw/`)은 커밋하지 않는다. 다 끝나면 지워도 된다.
6. **정리**: 대조 리스너(1)를 Ctrl-C로 멈춘다. 2에서 python을 허용했다면 (MANUAL, sudo 필요) `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --remove "$PY_REAL"` 후 `/usr/libexec/ApplicationFirewall/socketfilterfw --listapps`(sudo 불필요)로 빠졌는지 본다. Colima를 쓴다면 이제 다시 켜도 된다.
7. **판정**:
   ```sh
   scripts/verify/m1-lan-scan.sh --vm-off docs/evidence/m1/lan-scan-base-vm-off.gnmap --vm-on docs/evidence/m1/lan-scan-base-vm-on.gnmap
   ```
   PASS여야 한다: 모든 `Host:` 줄이 `<LAN_IP>` 하나, nmap 명령 줄에 `-n -Pn -p- -oG`, 각 `Host:` 줄이 65535개 포트를 다룸(나열 + `Ignored State`), VM 켜짐/꺼짐의 열린 TCP 포트 목록이 같고, 22·80·443·6443·10250·20241·Lima SSH 포트가 열려 있지 않다.

다른 기기 메모 (더 강한 증거): 스캔 전에 Mac에서 `make lan-scan-guard`를 실행한다 (VM 끄기 전과 켠 뒤 각각). 같은 LAN의 다른 노트북 또는 안드로이드 Termux(`pkg install nmap`)에서 `nmap -n -Pn -p- -T4 -oG lan-scan-base-vm-off.gnmap <LAN_IP>`(VM 켠 뒤에는 `...-vm-on.gnmap`)를 실행하고, 파일을 USB나 본인 채널로 Mac에 옮긴다 (공개 붙여넣기 사이트 금지). Wi-Fi 클라이언트 격리가 켜진 네트워크는 18090도 막혀 스캔이 무효가 된다. 각 파일 맨 위에 `# scanner: device`, `# control-port: 18090`, `# firewall-state: ...`, `# firewall-allowance: ...` 네 줄을 직접 넣고(기기 이름·IP는 적지 않는다; 허용했다면 `# firewall-python: ...`, `# firewall-python-resolved: ...`도) 5의 치환을 한다. nmap의 `-oG` 형식만 받는다.
