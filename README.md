# workload

Kustomize manifests cho hệ thống food-review (Kubernetes local: minikube/kind/Docker Desktop).

## Cài minikube (Windows, driver docker)

Yêu cầu Docker Desktop đã cài và đang chạy.

```powershell
winget install -e --id Kubernetes.minikube --source winget
minikube start --driver=docker --cpus=2 --memory=4096
```

**Nếu `minikube start` báo lỗi `x509: certificate signed by unknown authority`**: nguyên nhân thường gặp là phần mềm diệt virus (Avast/Kaspersky/ESET...) có tính năng "HTTPS Scanning"/Web Shield chặn và giải mã lại TLS, kể cả trên `127.0.0.1`. Tắt tính năng đó (vd Avast: Settings → Protection → Core Shields → Web Shield → tắt "Enable HTTPS Scanning"), sau đó `minikube delete --all --purge` rồi `minikube start` lại.

## Cấu trúc

- `infra/` — hạ tầng dùng chung giữa các backend service: Postgres, Redis, MinIO. `base/` chứa manifest gốc, `overlays/<env>/` set namespace + secret theo từng môi trường.
- `apps/<service-name>/` — mỗi backend service một thư mục, cùng khuôn `base/` + `overlays/dev,stg/`. Hiện có `food-review-backend`.
- `envs/<env>/` — gom `infra/overlays/<env>` + tất cả `apps/*/overlays/<env>` để deploy nguyên namespace bằng 1 lệnh.

Namespace: `food-review-dev`, `food-review-stg` (tạo bởi `infra/overlays/<env>/namespace.yaml`).

## Chuẩn bị lần đầu

1. Copy các file `*.secret.env.example` thành `*.secret.env` (cùng thư mục) và điền giá trị thật — các file `*.secret.env` đã bị gitignore, không commit.
   - `infra/overlays/dev/postgres.secret.env`, `infra/overlays/dev/minio.secret.env`
   - `apps/food-review-backend/overlays/dev/secret.env`
   - (tương tự cho `stg`)
2. Bật ingress addon: `minikube addons enable ingress` (hoặc cài ingress-nginx nếu dùng kind).
3. **Nếu dùng driver `docker` trên Windows** (mặc định khi có Docker Desktop): `minikube ip` trả về IP nội bộ của container node (vd `192.168.49.2`), Windows host **không** route trực tiếp tới được. Cần chạy song song (cửa sổ terminal riêng, để chạy nền):
   ```bash
   minikube tunnel
   ```
   Lệnh này bind các Ingress/LoadBalancer về `127.0.0.1` trên host. Thêm vào hosts file (`C:\Windows\System32\drivers\etc\hosts`, cần quyền admin):
   ```
   127.0.0.1  food-review.dev.local
   127.0.0.1  food-review.stg.local
   ```
   (Nếu dùng driver dạng VM như `hyperv`/`virtualbox`, `minikube ip` trả về IP routable thật và không cần `minikube tunnel` — trỏ hosts file thẳng vào IP đó.)

   Để test nhanh không cần ingress/tunnel, dùng `kubectl port-forward` như phần Kiểm tra bên dưới.

## Build & load image backend

**`dev` overlay** giờ pull image từ Docker Hub (`ca0huuqu0c/food-review-backend:dev`) thay vì build local — xem phần [CI/CD](#cicd-tự-động-build--deploy-khi-merge-vào-main) bên dưới. Không cần `docker build`/`minikube image load` thủ công cho dev nữa.

**`stg` overlay** vẫn dùng flow build local cũ:
```bash
cd d:/spring/food-review
docker build -t food-review-backend:stg .
minikube image load food-review-backend:stg
```

## Deploy

Toàn bộ 1 namespace (infra + app) bằng 1 lệnh:

```bash
kubectl apply -k envs/dev
kubectl apply -k envs/stg
```

Hoặc deploy từng phần khi cần:

```bash
kubectl apply -k infra/overlays/dev
kubectl apply -k apps/food-review-backend/overlays/dev
```

## Kiểm tra

```bash
kubectl get pods -n food-review-dev
kubectl logs -n food-review-dev deploy/food-review-backend
curl http://food-review.dev.local/food-review/swagger-ui.html
```

## Thêm 1 backend service mới

1. Copy `apps/food-review-backend/` sang `apps/<service-name>/`, sửa lại image name, port, biến env trong `base/configmap.yaml` và `overlays/<env>/kustomization.yaml` theo config thật của service đó.
2. Nếu service dùng chung Postgres/Redis đã có trong `infra/`, chỉ cần trỏ `POSTGRES_HOST`/`REDIS_HOST` tới `<service>.<namespace>.svc.cluster.local` — không cần deploy infra riêng.
3. Thêm `../../apps/<service-name>/overlays/<env>` vào `resources` trong `envs/<env>/kustomization.yaml` để service mới được gồm trong lệnh apply 1 phát.

## CI/CD (tự động build + deploy khi merge vào main)

Kiến trúc: **self-hosted GitHub Actions runner** (chạy trên chính máy bạn, đăng ký với repo `Food-Review-BE`) đảm nhiệm build/push image — vì máy bạn cũng là nơi chạy minikube, nên không cần expose port hay dùng registry/GitOps controller phức tạp. Redeploy được tách thành 1 process **poll độc lập** (`scripts/watch-and-redeploy.ps1`) thay vì làm luôn trong CI job, để tách rời "ai build" khỏi "ai deploy".

```
PR mở lên Food-Review-BE
        │
        ▼
.github/workflows/pr-check.yml  (self-hosted runner)
  → mvnw spotless:check + mvnw clean verify -DskipTests
  → PR check pass/fail hiện trên GitHub

PR merge vào main
        │
        ▼
.github/workflows/build-push.yml  (self-hosted runner)
  → docker build, tag :<git-sha> và :dev
  → docker push lên Docker Hub (ca0huuqu0c/food-review-backend)

        │  (không có bước "deploy" nào trong CI — CI dừng lại ở đây)
        ▼
scripts/watch-and-redeploy.ps1  (chạy độc lập, liên tục trên máy bạn)
  → poll Docker Hub API mỗi 60s, so digest tag "dev"
  → phát hiện digest đổi → kubectl rollout restart
  → imagePullPolicy: Always → pod mới tự pull bản :dev mới nhất
```

### Setup 1 lần — self-hosted runner (trên repo `Food-Review-BE`)

1. Vào `https://github.com/WokCao/Food-Review-BE` → **Settings → Actions → Runners → New self-hosted runner** → chọn **Windows x64**.
2. Làm theo đúng các lệnh PowerShell GitHub hiển thị (tải, giải nén, `./config.cmd --url ... --token ...`). Khi được hỏi tên/label, để mặc định là được (workflow ở trên chỉ cần label `self-hosted`).
3. Chạy `./run.cmd` trong 1 cửa sổ terminal riêng và **để nguyên đó** — đây chính là "worker" nhận job từ GitHub. Đóng cửa sổ này là runner offline, CI sẽ không chạy được.
   *(Muốn chạy nền vĩnh viễn kể cả khi tắt terminal thì cài thành Windows Service bằng `./svc.cmd install` + `./svc.cmd start` — có thể làm sau khi đã quen luồng cơ bản.)*

### Setup 1 lần — Docker Hub secret (trên repo `Food-Review-BE`)

1. Tạo access token tại `hub.docker.com` → Account Settings → Security → **New Access Token** (quyền Read & Write là đủ).
2. Vào GitHub repo → **Settings → Secrets and variables → Actions → New repository secret**:
   - Name: `DOCKERHUB_TOKEN`
   - Value: token vừa tạo ở bước 1

(Username `ca0huuqu0c` đã hardcode thẳng trong workflow/manifest vì không phải thông tin nhạy cảm, không cần lưu secret riêng.)

### Setup 1 lần — cho phép runner gọi được `docker`/`kubectl`/`minikube`

Runner chạy dưới user hiện tại của bạn (nếu chạy `./run.cmd` thủ công, không phải Windows Service), nên nó thấy đúng PATH bạn đang dùng — không cần cấu hình thêm.

### Chạy listener redeploy

```powershell
cd d:\spring\workload
.\scripts\watch-and-redeploy.ps1
```
Để trong 1 terminal riêng, chạy song song với runner. Có thể chỉnh `-PollIntervalSeconds` nếu muốn phản ứng nhanh/chậm hơn.

### Kiểm tra end-to-end

1. Sửa code nhỏ ở backend → tạo PR → xem tab **Actions** trên GitHub, job `pr-check` chạy trên runner của bạn.
2. Merge PR → job `build-push` chạy, kiểm tra tag mới xuất hiện trên `hub.docker.com/r/ca0huuqu0c/food-review-backend/tags`.
3. Trong vòng tối đa 1 phút (theo `PollIntervalSeconds`), cửa sổ chạy `watch-and-redeploy.ps1` sẽ in ra "New digest detected" rồi tự rollout — `kubectl get pods -n food-review-dev -w` để xem pod mới lên.

## Nâng cấp sau này (chưa cần làm ngay)

- Secret hiện quản lý bằng file `.secret.env` local per-dev — khi lên cloud thật, chuyển sang `sealed-secrets` hoặc `external-secrets` để có thể commit an toàn.
- Nếu số service tăng nhiều và cấu hình lặp lại nhiều, cân nhắc chuyển từ Kustomize sang Helm (1 chart chung + `values-<service>-<env>.yaml`).
- CI/CD hiện tại là polling đơn giản (`watch-and-redeploy.ps1` hỏi Docker Hub mỗi 60s) — đủ để làm quen luồng CI/CD nhưng có độ trễ và là 1 process rời rạc phải tự chạy tay. Khi lên cluster thật (cloud), thay bằng GitOps controller (Argo CD/Flux) cài trong cluster, tự watch repo `workload` và tự sync — không cần polling registry thủ công nữa (xem lại giải thích luồng GitOps đã trao đổi trước đó trong hội thoại).
