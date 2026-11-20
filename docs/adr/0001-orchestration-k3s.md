# ADR-0001 오케스트레이션: K3s

- 상태: 채택 (2026-11-11)
- 표기: 결정 출처 **[사용자 결정]** (K3s 사용은 사용자 브리프에 있음) / 비교와 근거 정리 **[Claude 제안]**
- 공통 기준과 가중치: 설계 문서 §24.1 (필수 조건 G1~G4, 가중 기준 C2~C7, 점수 1~5는 Claude 평가로 주관이 섞여 있음)

## 결정
단일 노드 **K3s**로 모든 워크로드를 운영한다. 기본 포함 구성요소(Traefik, ServiceLB, local-path, 내장 NetworkPolicy 컨트롤러)를 그대로 쓴다.

## 맥락
- 보여줄 보안 통제 중 상당수가 **쿠버네티스 기능**이다: NetworkPolicy(네트워크 격리), ServiceAccount(OpenBao Kubernetes auth와 Relay 앱 인증의 신원), Pod Security Admission, Secret 암호화.
- 자원은 2 OCPU / 12 GB ARM 한 대뿐이다. 컨트롤 플레인이 가벼워야 한다.
- 1인 운영이라 설치와 업그레이드가 단순해야 한다.

## 비교 후보
K3s, k0s, MicroK8s, kind/minikube, Docker Compose, 매니지드 쿠버네티스(OCI OKE)

## 비교표
| 후보 | 필수 조건 | C2 자원 적합 (25%) | C3 보안 기여 (25%) | C4 1인 운영 (20%) | C5 라이선스 (10%) | C6 채택도 (10%) | C7 이식성 (10%) | 가중 합 |
|---|---|---|---|---|---|---|---|---|
| **K3s** | 통과 | 5 | 5 | 4 | 5 | 4 | 5 | **4.70** |
| k0s | 통과 | 4 | 4 | 3 | 5 | 3 | 5 | 3.90 |
| Docker Compose | 통과 | 5 | 2 | 5 | 5 | 4 | 2 | 3.85 |
| MicroK8s | 통과 | 3 | 4 | 4 | 5 | 3 | 4 | 3.75 |
| kind/minikube | 통과 (단, 상시 운영용 아님) | 3 | 2 | 4 | 5 | 4 | 3 | 3.25 |
| OCI OKE | **탈락 (G1)**: Always Free 계정에서 지원되지 않아 유료(PAYG) 전환이 필요하다는 보고가 다수. 비용 가드레일(PAYG 금지) 위반 | — | — | — | — | — | — | — |

근거 메모:
- K3s 서버 최소 요구: 2코어, 2 GB RAM. 프로젝트 자체 프로파일링에서 단순 워크로드 기준 약 1.6 GB.
- k0s: 컨트롤러 1 vCPU / 1 GB 문서화. 내장 Ingress가 없어 직접 골라 설치해야 하고 기본 CNI(kube-router)도 별도로 이해해야 한다.
- MicroK8s: 유휴 540 MB를 내세우지만 워크로드용으로 4 GB를 권장한다. snap 기반이고 Ubuntu 쪽에 치우친다.
- kind/minikube: 개발·테스트용이다. 컨테이너 안에 노드를 띄우는 구조라 "실제 운영 중인 클러스터를 공격해 본다"는 시연이 약해진다. CI E2E 용도(k3d 포함)로는 쓴다.
- Docker Compose: 가장 단순하지만 Pod 단위 신원(ServiceAccount)이 없어 OpenBao Kubernetes auth, Relay의 SA 토큰 인증을 그대로 할 수 없다. 네트워크 분리는 가능하지만 "출발지 라벨 × 목적지 포트" 단위의 정책, PSA 같은 수준의 통제는 없다.

## 왜 이것인가
1. 이 프로젝트의 보안 증거(S2 연결 매트릭스, S7·S9 신원 기반 거부)는 쿠버네티스의 **워크로드 신원과 네트워크 정책**에 기대고 있다. Compose로는 같은 주장을 같은 방식으로 증명할 수 없다.
2. K3s는 단일 바이너리이고 Ingress, LB, 스토리지, NetworkPolicy 컨트롤러가 이미 들어 있다. 12 GB 안에서 앱에 쓸 메모리를 가장 많이 남긴다.
3. CNCF 인증 쿠버네티스 배포판이므로 매니페스트를 다른 클러스터(EKS, GKE, OKE)로 거의 그대로 옮길 수 있다. 쿠버네티스 경험은 그대로 실무로 이어진다.

## 포기한 것 (트레이드오프)
- 매니지드 컨트롤 플레인의 편의(업그레이드, 백업)를 포기하고 직접 관리한다.
- 단일 노드라 HA, 노드 장애 대응은 없다 (비목표).
- 기본 SQLite 데이터스토어를 쓰므로 etcd 운영 경험은 생기지 않는다.

## 결정을 바꾸게 될 조건
- 노드가 2대 이상으로 늘고 HA가 목표가 되면: K3s embedded etcd 또는 RKE2 검토.
- 비용 제약이 풀리면: OKE/EKS 같은 매니지드로 옮기고 컨트롤 플레인 하드닝 대신 IAM·워크로드 아이덴티티 시연에 집중.
- 메모리가 8 GB 미만으로 더 줄면: Compose로 낮추고 NetworkPolicy 시연을 Docker 네트워크 분리로 대체 (주장 범위 축소를 README에 명시).

## 면접용 한 줄 답변
"보여주려는 보안 통제가 서비스어카운트 신원과 네트워크 정책 같은 쿠버네티스 기능이라 Compose로는 증명이 안 되고, 12GB 단일 ARM 노드에서 Ingress·LB·NetworkPolicy 컨트롤러까지 기본 포함된 가장 가벼운 인증 배포판이 K3s였습니다."

## 근거 URL
- K3s 요구사항: https://docs.k3s.io/installation/requirements
- K3s 네트워킹(내장 NetworkPolicy 컨트롤러, Traefik): https://docs.k3s.io/networking/networking-services
- k0s/MicroK8s 비교(최소 메모리): https://pickuma.com/for-dev/k3s-vs-microk8s-vs-k0s-lightweight-kubernetes-small-teams/
- MicroK8s 시작하기: https://canonical.com/microk8s/docs/getting-started
- OKE와 Always Free 계정(유료 전환 필요 보고): https://github.com/cablespaghetti/oracle-cloud-kubernetes , https://calvin.me/kubernetes-on-oracle-cloud-free-tier/
