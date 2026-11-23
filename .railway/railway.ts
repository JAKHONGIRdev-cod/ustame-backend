import { defineRailway, github, project, service } from "railway/iac";
// This repository manages only its own resources in the environment. Other
// repositories export their own partial name.
// See https://docs.railway.com/infrastructure-as-code#multi-repo-projects
export const partial = "ustame-backend";
export default defineRailway(() => {
  const ustameBackend = service("ustame-backend", {
    source: github("JAKHONGIRdev-cod/ustame-backend", { branch: "main", checkSuites: false }),
    build: { buildEnvironment: "V3", builder: "DOCKERFILE", dockerfilePath: "Dockerfile" },
    healthcheck: "/healthz",
    healthcheckTimeout: 60,
    // railway.json'dagi kabi: yiqilsa 5 martagacha qayta ishga tushadi
    deploy: { restartPolicyType: "ON_FAILURE", restartPolicyMaxRetries: 5 },
    replicas: { "asia-southeast1-eqsg3a": 1 },
  });

  return project("ustame", {
    variables: { managed: false },
    resources: [ustameBackend],
  });
});
