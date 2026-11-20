# ADR-0008 네트워크 정책: K3s 내장 NetworkPolicy 컨트롤러

- 상태: 채택 (2026-11-11)
- 표기: 결정 **[Claude 제안]** / 공통 기준은 설계 문서 §24.1

## 결정
K3s 기본 구성(Flannel CNI + kube-router netpol 라이브러리 기반 **내장 NetworkPolicy 컨트롤러**)을 그대로 쓰고, 표준 `NetworkPolicy`만으로 default-deny와 §10 허용 매트릭스를 구현한다.

## 맥락
- 필요한 것은 L3/L4 격리다: "누가 누구에게 어떤 포트로"(§10). L7 경로 제한은 포트 분리(relay-reveal 8001/8002)로 대신한다.
- CNI를 바꾸려면 K3s 설치 옵션(`--flannel-backend=none`, `--disable-network-policy`)을 바꾸고 별도 컴포넌트를 운영해야 한다.

## 비교 후보
K3s 내장 컨트롤러, Cilium, Calico

## 비교표
| 후보 | 필수 조건 | C2 (25%) | C3 (25%) | C4 (20%) | C5 (10%) | C6 (10%) | C7 (10%) | 가중 합 |
|---|---|---|---|---|---|---|---|---|
| **K3s 내장** | 통과 | 5 | 3 | 5 | 5 | 3 | 5 | **4.30** |
| Calico | 통과 | 3 | 4 | 3 | 5 | 5 | 4 | 3.75 |
| Cilium | 통과 | 2 | 5 | 2 | 5 | 5 | 4 | 3.55 |

| 기능 | K3s 내장 | Calico | Cilium |
|---|---|---|---|
| 표준 NetworkPolicy (ingress/egress) | ○ | ○ | ○ |
| L7(HTTP 메서드·경로) 정책 | × | △ (일부, 별도 구성) | ○ |
| FQDN 기반 egress | × | △ (엔터프라이즈 기능 위주) | ○ |
| 호스트(노드) 엔드포인트 보호 | × | ○ (GlobalNetworkPolicy, HostEndpoint) | ○ |
| 흐름 관측 (증거 수집) | × | △ | ○ (Hubble) |
| 추가 메모리 | 거의 0 | 수백 MB 수준 (추정) | 에이전트만 노드당 수백 MB, BPF 맵 별도 |
| 라이선스 | Apache-2.0 (K3s) | Apache-2.0 (오픈소스판) | Apache-2.0 |

## 왜 이것인가
1. 이 프로젝트의 격리 요구는 표준 NetworkPolicy로 전부 표현된다. 표준만 쓰므로 정책 파일을 다른 CNI로 그대로 옮길 수 있다 (이식성).
2. 추가 메모리가 사실상 0이다. Cilium 에이전트는 노드당 수백 MB를 쓰는데, 12 GB 노드에서는 Ollama 몫과 직접 경쟁한다.
3. 1인 운영에서 CNI 교체는 장애 원인을 늘린다. "기본 구성으로도 default-deny를 제대로 하면 이만큼 막힌다"는 것 자체가 실무에서 쓸모 있는 메시지다.

## 포기한 것 (트레이드오프)
- FQDN egress 제한이 없다. 외부로 나가야 하는 Pod는 `0.0.0.0/0:443`처럼 넓게 열어야 한다. 그래서 **[Claude 결정(리뷰 반영)]** **외부 egress 예외는 `audit-anchor` CronJob 하나뿐**으로 줄였다 (1시간 주기, 전용 ns, 443 egress만, OCI Object Storage 쓰기 전용 PAR만 보유, 반출 대상은 감사 해시체인 헤드와 OpenBao audit 해시 요약). 외부 LLM은 쓰지 않고, Ollama 모델은 설치 때 한 번 쓰고 지우는 Job으로 받는다.
- L7 정책 대신 포트를 나누는 우회를 쓴다.
- Hubble 같은 흐름 관측이 없어, 차단 증거는 `nc` 기반 연결 매트릭스 스크립트로 만든다.
- 노드(hostNetwork) 트래픽은 표준 NetworkPolicy 범위 밖이다 (§22).

## 결정을 바꾸게 될 조건
- 외부 API 호출이 상시 필요해지면(FQDN 제한 필요), 또는 `audit-anchor`의 443 egress를 OCI Object Storage 도메인으로 좁히고 싶어지면: Cilium.
- 노드 자체를 정책으로 보호하고 싶어지면: Calico HostEndpoint 또는 Cilium host firewall.
- 흐름 로그를 증거로 보여주고 싶고 메모리 여유가 생기면: Cilium + Hubble.

## 면접용 한 줄 답변
"필요한 건 L3/L4 격리였고 표준 NetworkPolicy로 전부 표현돼서, K3s 내장 컨트롤러로 추가 메모리 없이 default-deny를 구현했습니다. 대신 FQDN 제한이 안 되는 한계가 있어서, 외부 egress 예외를 감사 앵커를 올리는 CronJob 하나로 줄였고 그 CronJob도 쓰기 전용 자격 증명만 갖게 했습니다."

## 근거 URL
- K3s 내장 NetworkPolicy 컨트롤러: https://docs.k3s.io/networking/networking-services
- K3s CNI 비교(Flannel·Calico·Cilium과 NetworkPolicy): https://www.tobias-weiss.org/content/devops/k3s-distributions-cni-comparison/
- Cilium 메모리 관련(이슈·스케일 보고서): https://docs.cilium.io/en/latest/operations/performance/scalability/report/ , https://github.com/cilium/cilium/issues/32940
- Calico를 K3s에 적용: https://oneuptime.com/blog/post/2026-03-20-k3s-replace-flannel-calico/view
