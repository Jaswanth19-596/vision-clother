import type { HttpsOptions } from "firebase-functions/v2/https";

/**
 * Per-function Cloud Run scaling knobs, kept out of `index.ts` so capacity
 * can be retuned (dev → production) by editing values here only — no
 * function-definition changes, no risk of drifting `cpu`/`concurrency` out
 * of the constraint that Cloud Run gen2 forces `concurrency` to 1 whenever
 * `cpu` is fractional, regardless of `memory` tier.
 *
 * Current values are **early-development defaults sized for ~10 active
 * users total**, deliberately far below what `docs/backend/architecture.md`
 * documents as the production target. `minInstances: 0` on all three lets
 * every function scale to zero when idle, which is the right tradeoff at
 * this traffic level (occasional cold starts) over paying for warm
 * instances nobody is using yet.
 */
type ScalingConfig = Pick<
  HttpsOptions,
  "cpu" | "memory" | "concurrency" | "maxInstances" | "minInstances"
>;

export const scalingConfig: Record<"proxyApi" | "heavyApi" | "accountApi", ScalingConfig> = {
  proxyApi: {
    cpu: 1,
    memory: "256MiB",
    concurrency: 5,
    maxInstances: 3,
    minInstances: 0,
  },
  heavyApi: {
    cpu: 1,
    memory: "512MiB",
    concurrency: 2,
    maxInstances: 2,
    minInstances: 0,
  },
  accountApi: {
    cpu: 1,
    memory: "256MiB",
    concurrency: 5,
    maxInstances: 3,
    minInstances: 0,
  },
};
