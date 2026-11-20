# ADR-0007 LLM 런타임과 모델: Ollama + 소형 모델 (외부 API 사용 안 함)

- 상태: 채택 (2026-11-11). 모델은 M5에서 측정 후 확정
- 표기: 런타임 결정 **[Claude 제안]**, "외부 LLM API 사용 안 함"은 **[사용자 결정]** (Gemini 무료 티어 제거 지시)
- 공통 기준은 설계 문서 §24.1

## 결정
- 런타임: 클러스터 안의 **Ollama** (CPU, arm64). Pod egress는 전부 막는다.
- 모델: **1.5B~3B급, Q4 양자화**. 첫 후보는 Qwen3 1.7B (Apache-2.0). M5에서 한국어 분류 테스트셋으로 비교해 확정한다.
- 외부 LLM API(Gemini, OpenAI 등)는 **쓰지 않는다**.
- 분류와 답변 초안은 **비동기**(작업 큐 + worker)로 처리한다. 2 OCPU라 응답이 수 초~수십 초 걸린다 (추정).

## 맥락
- 프로젝트 메시지가 "개인정보가 밖으로 나가지 않는다"이므로, 마스킹했더라도 외부 전송 자체를 없애는 편이 주장과 일치한다.
- Gemini API 무료 티어 약관은 입력과 응답을 Google 제품 개선에 쓰고, 사람이 검토할 수 있으며, 민감 정보나 개인정보를 넣지 말라고 명시한다. 유료 API는 0원 제약을 깬다.
- 메모리 예산 중 LLM 몫은 약 4 GB이다.

## 비교 후보
런타임: Ollama, llama.cpp server, vLLM(CPU 백엔드), 외부 API(Gemini, OpenAI)

## 비교표 (런타임)
| 후보 | 필수 조건 | C2 (25%) | C3 (25%) | C4 (20%) | C5 (10%) | C6 (10%) | C7 (10%) | 가중 합 |
|---|---|---|---|---|---|---|---|---|
| **Ollama** | 통과 | 4 | 4 | 5 | 5 | 4 | 4 | **4.30** |
| llama.cpp server | 통과 | 5 | 4 | 3 | 5 | 4 | 4 | 4.15 |
| vLLM (CPU) | 통과 | 2 | 4 | 2 | 5 | 4 | 4 | 3.20 |
| Gemini 무료 티어 | **탈락 (G4)**: 입력이 제품 개선에 쓰이고 사람이 검토할 수 있음. 프로젝트 메시지와 충돌 | — | — | — | — | — | — | — |
| OpenAI 등 유료 API | **탈락 (G1)**: 비용 발생 | — | — | — | — | — | — | — |

메모:
- Ollama는 내부적으로 llama.cpp 계열 엔진을 쓰면서 모델 내려받기, 버전 태그, REST API를 묶어 준다. 1인 운영에서 "모델 관리"가 쉬워지는 것이 가장 큰 차이다. 라이선스 MIT.
- llama.cpp server는 더 가볍고 세밀하게 조정할 수 있지만 GGUF 파일 관리와 빌드 옵션을 직접 다뤄야 한다. 메모리가 더 빠듯해지면 1순위 대안이다.
- vLLM은 GPU 처리량에 최적화된 서버다. ARM CPU 백엔드는 기본 추론만 지원하고(FP32/FP16/BF16), 이 규모에선 무겁다.

## 모델 후보 (Q4 기준, 크기는 Ollama 라이브러리 표기 또는 추정)
| 모델 | 크기 | 라이선스 | 한국어 | 메모 |
|---|---|---|---|---|
| **Qwen3 1.7B** | 다운로드 약 1.4 GB (Q4_K_M) | Apache-2.0 | 다국어 지원 | 첫 후보. 사고(thinking) 모드는 끄고 쓴다 |
| Qwen3 4B | 약 2.5 GB (추정) | Apache-2.0 | 다국어 지원 | 품질이 부족하면 상향 후보. 메모리 limit 4 GiB 안쪽인지 측정 필요 |
| Qwen2.5 1.5B Instruct | 약 1 GB, 실행 약 2 GB | Apache-2.0 | 다국어 | 안정적인 대안 |
| Qwen2.5 3B Instruct | 약 1.9 GB | **Qwen Research License (연구·평가용, 상업 이용 제한)** | 다국어 | 제품화 로드맵과 충돌하므로 비교 실험용으로만 |
| Llama 3.2 3B | 약 2 GB (추정) | Llama 3.2 Community License | 공식 지원 언어에 한국어 없음 | 참고용 |
| Gemma 3 1B / 4B | 추정 1~3 GB | Gemma Terms of Use | 다국어 | 약관 확인 필요 |
| EXAONE 3.5 2.4B | 추정 1.5~2 GB | 비상업 연구용 라이선스 (확인 필요) | 한국어 강점 | 품질 기준선 비교용 |

- 평가 방법: SafeDesk 문의 50건 내외의 한국어 테스트셋(마스킹된 문장)으로 카테고리 정확도, 긴급도 일치율, JSON 형식 준수율, 건당 처리 시간, 최대 메모리를 측정한다. 결과를 이 ADR에 추가한다.

## 왜 이것인가
1. **외부 전송 0건**을 구조로 보장한다. Ollama Pod에는 egress가 없고(모델은 별도 Job으로 받음), S4에서 프롬프트에 마스킹본만 들어간다는 것과 함께 "LLM 경로로는 원본이 나갈 길이 없다"를 증명한다.
2. 1인 운영에서 모델 교체가 `ollama pull` 한 번이라 M5의 모델 비교 실험이 쉽다.
3. 분류·초안은 실시간일 필요가 없어서, CPU 추론의 느림을 비동기 처리로 흡수할 수 있다.

## 포기한 것 (트레이드오프)
- 대형 모델 수준의 품질을 포기한다. 초안은 "상담원이 고쳐 쓰는 출발점"으로 범위를 정한다.
- 처리 지연(수 초~수십 초)을 감수한다.
- CPU 2개 중 상당 부분을 추론이 쓰므로, 추론 중에는 다른 서비스 응답이 느려질 수 있다. worker 동시 처리 수를 1로 제한하고 Ollama에 CPU limit을 건다.

## 결정을 바꾸게 될 조건
- 메모리가 더 빠듯해지면: llama.cpp server로 바꾸거나 0.6B~1B 모델로 낮춘다.
- 품질이 업무에 쓸 수준이 안 되면: LLM은 분류만 맡기고 초안은 템플릿으로 바꾼다.
- 비용 제약이 풀리면: 데이터 비보관·학습 미사용이 계약으로 보장되는 유료 API를 "마스킹본만" 조건으로 검토한다 (그래도 기본값은 내부 모델).

## 면접용 한 줄 답변
"메시지가 '개인정보가 밖으로 안 나간다'여서 외부 API는 아예 뺐습니다. Gemini 무료 티어는 약관상 입력이 제품 개선에 쓰이기 때문입니다. 대신 클러스터 안 Ollama에 1~2B급 모델을 올리고 egress를 막았고, CPU라 느린 부분은 비동기 처리로 흡수했습니다."

## 근거 URL
- Gemini API 추가 약관(무료 서비스 데이터 사용): https://ai.google.dev/gemini-api/terms
- Ollama Qwen3 1.7B(크기, 라이선스): https://ollama.com/library/qwen3:1.7b
- Qwen3 저장소(Apache-2.0): https://github.com/QwenLM/Qwen3
- Qwen2.5-3B 라이선스(Qwen Research License): https://huggingface.co/Qwen/Qwen2.5-3B/blob/main/LICENSE
- Ollama Qwen2.5 3B: https://ollama.com/library/qwen2.5:3b
- 소형 모델 CPU 속도·메모리(참고, 2차 자료): https://localaimaster.com/models/qwen-2-5-coder-1-5b , https://dev.to/pavelespitia/how-much-ram-do-you-really-need-to-run-llms-locally-2026-benchmarks-3kd2
- vLLM CPU(ARM 지원 범위): https://docs.vllm.ai/en/latest/getting_started/installation/cpu/
