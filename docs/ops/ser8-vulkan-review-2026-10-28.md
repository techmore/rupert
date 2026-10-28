# SER8 Vulkan and local answer review — 2026-10-28

The SER8 has an AMD Radeon 780M using RADV and Mesa 26.0.8. The isolated test compared llama.cpp commit `19ff817fb` with the backend changes from [llama.cpp PR 30280](https://github.com/ggml-org/llama.cpp/pull/30280); the PR's tests were relocated for the newer base. This is an unmerged patch, not a release. The live model server remained running. The test builds and binaries were separate from production.

Both f16 and Q4_K 512×512×2048 matrix operations passed the patched Vulkan backend's comparison with the CPU reference. This is a targeted check, not full correctness coverage, and it did not instrument whether the new split-K branch was dispatched.

| Model | Workload | Baseline tokens/s | Patched tokens/s | Change |
|---|---|---:|---:|---:|
| LFM3 1.7B Q4_K_M | Prompt 512 | 1495.4 | 1499.2 | +0.3% |
| LFM3 1.7B Q4_K_M | Prompt 2,048 | 1493.7 | 1490.5 | -0.2% |
| LFM3 1.7B Q4_K_M | Generate 128 | 66.1 | 65.6 | -0.7% |
| Qwen3.5 4B Q4_K_M | Prompt 512 | 538.1 | 535.8 | -0.4% |
| Qwen3.5 4B Q4_K_M | Prompt 2,048 | 530.1 | 528.6 | -0.3% |
| Qwen3.5 4B Q4_K_M | Generate 128 | 24.5 | 24.4 | -0.3% |

Each number is a synthetic `llama-bench` tokens-per-second measurement, not an end-to-end chat response time. Two invocations per build and model were run in baseline, patch, patch, baseline order; each invocation had two repetitions per case. Settings were GPU layers 99, eight threads, flash attention on, batch 2048 and microbatch 512. The existing model server remained loaded and other activity was not controlled, so small differences are noise rather than evidence of a gain. A lock kept these experiments from overlapping our other benchmark jobs, but did not exclude production traffic. The result does not establish performance for other hardware, contexts, quantizations, or concurrent workloads.

The patch was not adopted: the measurements did not demonstrate a useful gain on these workloads. The upstream Qwen gated DeltaNet draft requires a Vulkan extension not exposed by this driver's current configuration, so it was not applied.

## Queue routing probe

Three new synthetic queue questions were selected before testing LFM3 against the previous code and a candidate that prioritized the queue tool. Both versions returned the requested counts for all three, but added large amounts of unrelated queue or compliance information; the candidate's first answer grew from 2,595 to 4,672 characters. The other two lengths were unchanged at 2,595 and 2,957 characters. This was one run per question, on the same synthetic fixture, without a hosted grader. It does not establish a general regression, but does not validate the proposed routing change. The candidate was reverted in `f643220f`.
