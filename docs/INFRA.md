---
level: 2
mode: reference
status: active
last_verified: 2026-07-09
confidence: 1.0
owners: [송준서, 이용찬, 박세현]
description: mochi-backend GCP 배포·운영 런북. 서버를 처음부터 배포하는 절차, SSH 접근 정책(송준서 단독), 실제로 겪은 함정과 주의사항. 인프라 배포·운영·장애 대응 시 읽는다.
---

# INFRA.md — mochi-backend GCP 배포 · 운영 런북

> 2026-06-08 최초 배포 기준. 실제로 프로비저닝하며 겪은 함정까지 포함한 재현 가능한 런북.
> 배포 토폴로지를 바꾸면 이 문서와 `docs/ARCHITECTURE.md`(Agent worker 섹션)를 함께 갱신한다.

---

## 0. 현재 배포 상태 (한눈에)

| 항목 | 값 |
| --- | --- |
| GCP 프로젝트 | `axial-device-460408-i9` (기존 서비스와 공유 — **mochi 리소스는 전부 `mochi-*` 네이밍 + 전용 VPC 로 격리**) |
| 리전 / 존 | `asia-northeast3` (서울) / `asia-northeast3-c` |
| VPC / 서브넷 | `mochi-vpc` / `mochi-subnet` (`10.30.0.0/24`) |
| 서비스 VM | `mochi-svc` — e2-small, static 외부 `34.64.104.136`, 내부 `10.30.0.3` |
| DB VM | `mochi-db` — e2-medium, **외부 IP 없음(내부 전용)**, 내부 `10.30.0.2` |
| 공개 도메인 | `https://34-64-104-136.nip.io` (Caddy 자동 Let's Encrypt) |
| 런타임 SA | `mochi-backend-sa@axial-device-460408-i9.iam.gserviceaccount.com` |
| 캡처 버킷 | `gs://mochi-captures-axial-device-460408-i9` |
| 비밀값 | Secret Manager: `mochi-auth-access-secret`, `mochi-db-password`, `mochi-apns-p8-base64`, `mochi-voyage-api-key`, `mochi-youtube-api-key`, `mochi-naver-client-id`, `mochi-naver-client-secret`, `mochi-google-places-api-key` |
| 앱 | systemd `mochi.service` (uvicorn, `/opt/mochi`, `WORKER_CONCURRENCY=2`) |
| DB | `pgvector/pgvector:pg16` 컨테이너 (`docker`, host volume `/var/lib/mochi-pg`) |

**비용**: 약 $50/월 (서울 e2-small + e2-medium + 디스크 + static IP). Cloud NAT 미사용으로 ~$32/월 절감.

---

## 1. 아키텍처 토폴로지

```
                  인터넷
                    │  443 (HTTPS)
                    ▼
        ┌───────────────────────────┐
        │  mochi-svc (e2-small)      │  34.64.104.136 (static)
        │  Caddy :443 (자동 TLS)     │  10.30.0.3
        │    └─► uvicorn 127.0.0.1:8000 (systemd mochi.service)
        │         WORKER_CONCURRENCY=2 (native async 코루틴)
        └───────────┬───────────────┘
                    │ 5432 (내부 전용, svc 태그만 허용)
                    ▼
        ┌───────────────────────────┐
        │  mochi-db (e2-medium)      │  10.30.0.2 (외부 IP 없음)
        │  docker: pgvector/pg16     │
        └───────────────────────────┘

  mochi-vpc (10.30.0.0/24) — 기존 inseoul/nowalba/union VPC 와 완전 분리
  방화벽: 80,443 ← 0.0.0.0/0 (svc) │ 22 ← 35.235.240.0/20 IAP 만 │ 5432 ← svc→db
  SA mochi-backend-sa → VM 부착 → 키파일 없이 ADC 로 Vertex/GCS/Secret 접근
  Vertex AI(Gemini) · GCS(캡처) · Secret Manager 는 Google API (private google access)
```

핵심 설계 의도:
- **svc 만 외부 노출**, db 는 내부 전용. AI 추론·임베딩은 전부 Vertex AI API 라 GPU 불필요.
- **SA 부착 = 키파일 zero**. VM 메타데이터 서버가 ADC 토큰을 발급 → Vertex/GCS/Secret 호출.
- **Cloud NAT 안 씀** (비용). db 의 인터넷 아웃바운드(docker pull)는 셋업 시 임시 외부 IP 로만, 끝나면 제거.

---

## 2. 처음부터 배포하기 (런북)

> 모든 명령은 `gcloud` 가 `axial-device-460408-i9` / `asia-northeast3` 로 설정된 상태 가정.
> `gcloud config set project axial-device-460408-i9 && gcloud config set compute/region asia-northeast3`

### 2.1 사전 준비
- 필요 API (이미 활성): `compute`, `iap`, `secretmanager`, `aiplatform`, `storage`.
  `gcloud services enable compute.googleapis.com iap.googleapis.com secretmanager.googleapis.com aiplatform.googleapis.com storage.googleapis.com`
- 실행자 권한: `roles/owner` 또는 (compute.admin + iam.serviceAccountAdmin + secretmanager.admin + resourcemanager.projectIamAdmin).

### 2.2 네트워크 (VPC · 서브넷 · 방화벽)
```bash
gcloud compute networks create mochi-vpc --subnet-mode=custom --bgp-routing-mode=regional
gcloud compute networks subnets create mochi-subnet \
  --network=mochi-vpc --region=asia-northeast3 --range=10.30.0.0/24 \
  --enable-private-ip-google-access            # db 가 외부IP 없이 Google API 접근

gcloud compute firewall-rules create mochi-allow-iap-ssh \
  --network=mochi-vpc --action=ALLOW --rules=tcp:22 \
  --source-ranges=35.235.240.0/20 --target-tags=mochi-ssh      # IAP 전용 SSH
gcloud compute firewall-rules create mochi-allow-https \
  --network=mochi-vpc --action=ALLOW --rules=tcp:80,tcp:443 \
  --source-ranges=0.0.0.0/0 --target-tags=mochi-svc
gcloud compute firewall-rules create mochi-allow-internal-db \
  --network=mochi-vpc --action=ALLOW --rules=tcp:5432 \
  --source-tags=mochi-svc --target-tags=mochi-db               # svc→db 만
```
⚠️ `10.30.0.0/24` 는 기존 대역(10.178/10.20/10.10/10.8)과 안 겹치게 고른 값. 새 서브넷 추가 시 `gcloud compute networks subnets list` 로 충돌 먼저 확인.

### 2.3 서비스 어카운트 · 버킷 · static IP · 비밀값
```bash
PROJECT=axial-device-460408-i9
SA=mochi-backend-sa@${PROJECT}.iam.gserviceaccount.com

gcloud iam service-accounts create mochi-backend-sa --display-name="Mochi backend runtime"
for R in roles/aiplatform.user roles/secretmanager.secretAccessor roles/logging.logWriter; do
  gcloud projects add-iam-policy-binding $PROJECT --member="serviceAccount:$SA" --role=$R --condition=None
done
# 캡처 이미지 GCS Signed URL 은 SA 가 자기 자신을 impersonate(signBlob) → self tokenCreator 필수
gcloud iam service-accounts add-iam-policy-binding $SA \
  --member="serviceAccount:$SA" --role=roles/iam.serviceAccountTokenCreator

gcloud storage buckets create gs://mochi-captures-${PROJECT} \
  --location=asia-northeast3 --uniform-bucket-level-access
gcloud storage buckets add-iam-policy-binding gs://mochi-captures-${PROJECT} \
  --member="serviceAccount:$SA" --role=roles/storage.objectAdmin

gcloud compute addresses create mochi-svc-ip --region=asia-northeast3

openssl rand -base64 48 | tr -d '\n' | gcloud secrets create mochi-auth-access-secret --data-file=-
openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32 | gcloud secrets create mochi-db-password --data-file=-
```

### 2.4 VM 2대
- startup-script 두 개 필요: `mochi-db-startup.sh`(docker + pgvector 컨테이너, 비번은 Secret 에서 metadata 토큰으로 fetch), `mochi-svc-startup.sh`(docker + caddy 설치). 본 저장소 배포 시 사용한 스크립트는 §부록 참조.
```bash
SA=mochi-backend-sa@axial-device-460408-i9.iam.gserviceaccount.com
gcloud compute instances create mochi-db \
  --zone=asia-northeast3-c --machine-type=e2-medium --subnet=mochi-subnet \
  --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud \
  --boot-disk-size=30GB --boot-disk-type=pd-balanced \
  --service-account=$SA --scopes=cloud-platform \
  --tags=mochi-db,mochi-ssh --metadata=enable-oslogin=TRUE \
  --metadata-from-file=startup-script=mochi-db-startup.sh
  # db 는 임시 외부 IP(기본 ephemeral)로 생성 → docker pull 후 §2.7 에서 제거

gcloud compute instances create mochi-svc \
  --zone=asia-northeast3-c --machine-type=e2-small \
  --subnet=mochi-subnet --address=mochi-svc-ip \
  --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud \
  --boot-disk-size=20GB --boot-disk-type=pd-balanced \
  --service-account=$SA --scopes=cloud-platform \
  --tags=mochi-svc,mochi-ssh --metadata=enable-oslogin=TRUE \
  --metadata-from-file=startup-script=mochi-svc-startup.sh
```

### 2.5 앱 배포 (svc)
```bash
# 1) 코드 tar — ⚠️ macOS 는 COPYFILE_DISABLE=1 로 AppleDouble 차단 (§5.1)
cd mochi-backend
COPYFILE_DISABLE=1 tar czf /tmp/mochi-backend.tar.gz \
  --exclude=.venv --exclude=__pycache__ --exclude='.*_cache' \
  --exclude=.git --exclude=.env --exclude=.DS_Store .
gzip -t /tmp/mochi-backend.tar.gz                       # 무결성 검증 (전송 손상 방지)

# 2) IAP scp → svc
gcloud compute scp /tmp/mochi-backend.tar.gz mochi-svc:~/ \
  --zone=asia-northeast3-c --tunnel-through-iap
# 원격에서도 gzip -t 로 재검증 권장 (scp 부분전송 사고 있었음)

# 3) svc 셋업: uv 설치 → 코드 /opt/mochi → Secret 으로 .env → uv sync → alembic → systemd
#    (세부는 mochi-backend/scripts/mochi-svc-setup.sh — repo 트리, .gitignore 미추적; 실배포본 VM ~/.
#     find /opt/mochi -name '._*' -delete 필수. .env 재생성만 필요하면 `bash ~/mochi-svc-setup.sh --env-only`)
```
`.env` 는 Secret Manager 값으로 svc 안에서 생성 (`ENVIRONMENT=production`, `DATABASE_URL=...@10.30.0.2:5432/mochi`, `GOOGLE_CLOUD_PROJECT`, `AUTH_ACCESS_SECRET`, `GCS_CAPTURE_BUCKET`, `GCS_SIGNER_SERVICE_ACCOUNT`, `WORKER_CONCURRENCY=2`, `DB_POOL_SIZE/MAX_OVERFLOW`, `TAVILY_API_KEY`(Secret `mochi-tavily-api-key`, 2026-07-09 신설), `VOYAGE_API_KEY`(Secret `mochi-voyage-api-key` — 검색·채팅 임베딩/리랭크, 2026-06-12), `VOYAGE_EMBEDDING_MODEL=voyage-4-large`(2026-07-09 voyage-3-large→voyage-4-large 정정 시 append. 코드 default 도 `voyage-4-large` 라 .env 가 재생성돼 이 키가 빠져도 안전 — §5.4 의 AUTH_GOOGLE_CLIENT_IDS 와 달리 fragile 하지 않음), `NAVER_CLIENT_ID`/`NAVER_CLIENT_SECRET`(findReferenceUrls tool — Secret `mochi-naver-client-id`/`mochi-naver-client-secret`, 2026-06-15), `YOUTUBE_API_KEY`(Secret `mochi-youtube-api-key` — recoverYoutubeUrl 무키검색 폴백, 2026-06-14), `GOOGLE_PLACES_API_KEY`(Secret `mochi-google-places-api-key` — searchPlaceGeo 별점·매장사진 보강, 미설정 시 보강만 생략, 2026-07-09)). `chmod 600 .env`.

### 2.6 Caddy TLS (svc)
```bash
sudo tee /etc/caddy/Caddyfile <<'EOF'
34-64-104-136.nip.io {
    reverse_proxy 127.0.0.1:8000
}
EOF
sudo systemctl reload caddy        # 첫 요청 시 Let's Encrypt 자동 발급 (80/443 열려 있어야)
```

### 2.7 DB 내부 전용 전환 + 검증
```bash
# db 외부 IP 제거 (셋업 끝났으니)
NAME=$(gcloud compute instances describe mochi-db --zone=asia-northeast3-c \
  --format="value(networkInterfaces[0].accessConfigs[0].name)")
gcloud compute instances delete-access-config mochi-db --zone=asia-northeast3-c --access-config-name="$NAME"

# 외부 검증
curl -sS --retry 10 --retry-delay 8 --retry-all-errors https://34-64-104-136.nip.io/api/v1/health
# → {"status":"ok"}
```

---

## 3. SSH 접근 정책 — 송준서 단독

SSH 는 **세 겹**으로 게이트한다:
1. **방화벽**: 22 번은 IAP 대역 `35.235.240.0/20` 에서만 (인터넷 직접 SSH 불가).
2. **IAP 터널**: 접속에 `roles/iap.tunnelResourceAccessor` 필요. 일반 사용자에겐 부여 안 함.
3. **OS Login**: VM 로그인에 `roles/compute.osAdminLogin` 필요. 송준서(`an001209@gmail.com`)만 보유.

접속 명령 (송준서):
```bash
gcloud compute ssh mochi-svc --zone=asia-northeast3-c --tunnel-through-iap
gcloud compute ssh mochi-db  --zone=asia-northeast3-c --tunnel-through-iap
```

### ⚠️ owner 는 이 게이트를 우회한다 (중요)
이 프로젝트는 다른 서비스와 **공유**라 `roles/owner` 가 **4명**이다: `an001209@gmail.com`(송준서) 외 `hanjm0211@gmail.com`, `hwang@indexfinger.app`, `sojpark722@gmail.com`. **owner 는 모든 권한을 갖기 때문에 위 3겹과 무관하게 IAP SSH 가 가능하다.** 비-owner 는 이미 차단되지만, owner 3명은 막을 수 없다.

**팀 결정 (2026-06-08): 현 상태 유지.** 저 3명은 mochi 와 무관한 팀원이고, 같은 공유 프로젝트라 owner 를 강등하면 그들의 다른 서비스(inseoul/nowalba/union 등) 권한까지 사라진다 — 그래서 **건드리지 않는다.** 비-owner 는 이미 IAP + OS Login 으로 차단되고, owner 3명은 팀 신뢰로 둔다. **owner 를 새로 추가하지 말 것.** 향후 완전 단독이 꼭 필요해지면 mochi 를 **별도 GCP 프로젝트로 분리**(owner=송준서만)하는 게 정석이며, 그때 전체 재배포한다.

---

## 4. 운영

| 작업 | 명령 (svc 안에서) |
| --- | --- |
| 앱 상태 | `sudo systemctl status mochi` |
| 앱 재시작 | `sudo systemctl restart mochi` |
| 앱 로그 | `sudo journalctl -u mochi -f` |
| DB 컨테이너 | (db 안) `sudo docker ps`, `sudo docker logs mochi-pg` |
| 코드 업데이트 | 새 tar scp → `/opt/mochi` 교체 → `uv sync --frozen --no-dev` → `uv run alembic upgrade head` → `sudo systemctl restart mochi` |
| 비밀값 회전 | `gcloud secrets versions add <name> --data-file=-` → svc `.env` 갱신 → restart |
| 동시성 조정 | `.env` 의 `WORKER_CONCURRENCY`(+필요 시 `DB_POOL_SIZE`) ↑ → restart. VM 키울 필요 없음 |

---

## 5. 조심할 것 (실제로 겪은 함정 + 주의)

### 5.1 macOS tar 의 AppleDouble → alembic `null bytes` 에러
macOS `tar` 는 파일마다 `._파일명` (AppleDouble, xattr/resource fork)을 같이 넣는다. Linux 에서 풀면 `alembic/versions/._xxxx.py` 가 생기고, alembic 이 이를 마이그레이션으로 오인해 **`SyntaxError: source code string cannot contain null bytes`** 로 죽는다.
- **예방**: tar 만들 때 `COPYFILE_DISABLE=1 tar ...`, 추출 후 `find /opt/mochi -name '._*' -delete`.
- bash glob `*.py` 는 `._*` 를 안 잡으니 `ls *.py` 진단에 안 보인다 — `ls -a` 또는 `find -name '._*'` 로 확인.

### 5.2 scp 전송 무결성
IAP scp 가 부분 전송으로 깨진 적 있다(`gzip: unexpected end of file`). **전송 후 원격에서 `gzip -t` 로 반드시 재검증**하고, 깨졌으면 재전송.

### 5.3 DB 외부 IP 없음 → docker pull / apt 불가
NAT 를 안 두므로 db 는 인터넷 아웃바운드가 없다. 이미지 교체·패키지 설치가 필요하면 **임시 외부 IP 부여 → 작업 → 제거** 한다:
```bash
gcloud compute instances add-access-config mochi-db --zone=asia-northeast3-c
#   ...작업...
gcloud compute instances delete-access-config mochi-db --zone=asia-northeast3-c --access-config-name="external-nat"
```
재부팅해도 `--restart=always` 라 컨테이너는 자동 기동(startup-script 의 apt 단계는 외부망 없으면 실패하지만 컨테이너 동작엔 무관).

### 5.4 production = dev 로그인 차단
`.env` 의 `ENVIRONMENT=production` 이라 `POST /auth/dev` 가 503 으로 막힌다(의도된 보안). **Apple 로그인은 운영 연결 완료**(`.env` `AUTH_APPLE_*` 명시 + iOS Release baseURL → 배포 백엔드, 2026-06-08). **Google 로그인도 운영 연결 완료**(2026-06-23): svc `/opt/mochi/.env` 에 `AUTH_GOOGLE_CLIENT_IDS`(iOS client id) append + `sudo systemctl restart mochi`, `/api/v1/health` ok. client id 는 공개 식별자라 Secret Manager 불필요·`.env` 직접. ✅ **함정 해결(2026-07-09)**: 예전엔 `.env` 가 재배포 setup 으로 재생성되면 수동 append 키가 사라졌다(setup 이 Secret 2개만 fetch). 이제 `mochi-svc-setup.sh` `.env` 생성부를 **live 26키 완전본**으로 확장 — 비밀 8개는 Secret Manager fetch(`mochi-tavily-api-key` 신설 포함), `AUTH_GOOGLE_CLIENT_IDS` 는 공개값 직접. `--env-only` dry-run 으로 재생성본이 live 와 값까지 26/26 동일함을 검증. 스크립트는 `mochi-backend/scripts/mochi-svc-setup.sh`(repo 트리, `.gitignore` 미추적 — 인프라 식별자·client id git 히스토리 비노출)로 편입, 실배포본은 VM `~/mochi-svc-setup.sh`. 푸시(`APNS_AUTH_KEY_P8_BASE64`)는 `mochi-apns-p8-base64` Secret(2026-06-08, key_id `CA6C3JCHW3`, EC 키 파싱 검증).

### 5.5 nip.io / static IP 결합
TLS 도메인이 `34-64-104-136.nip.io` = svc IP 임베드. **IP 가 바뀌면 도메인·인증서가 통째로 바뀐다.** 그래서 svc 는 반드시 **static IP**(`mochi-svc-ip`)여야 한다. 운영 도메인을 따로 살 거면 그 도메인 A 레코드 → svc IP, Caddyfile 의 도메인만 교체하면 자동 재발급.

### 5.6 Vertex 쿼터가 동시성 상한
`WORKER_CONCURRENCY` 를 올리면 동시 Gemini 호출이 늘어 flash-lite 쿼터(429)에 먼저 막힌다. 처리량 부족 시 VM 이 아니라 (a) 쿼터 상향, (b) 워커 수, (c) 인스턴스 복제 순으로 본다. DB 풀(`DB_POOL_SIZE+DB_MAX_OVERFLOW`)도 워커 수에 맞춰 올려야 starvation 없음 — `인스턴스수 × (pool+overflow) < Postgres max_connections(기본 100)`.

### 5.7 비밀값은 절대 코드/메타데이터 평문 금지
JWT secret·DB 비번은 Secret Manager 에만. VM 에 키파일 없음(SA + metadata ADC). `.env` 는 `chmod 600`. startup-script 에 비번을 평문으로 넣지 말 것(메타데이터는 describe 권한자에게 노출).

### 5.8 DB 백업·데이터 영속 (후속 권장)
현재 db 데이터는 boot 디스크의 host volume(`/var/lib/mochi-pg`)에 있다. VM 삭제 시 소실. prod 강건성을 위해 **별도 데이터 디스크 분리 + 스냅샷 스케줄**을 후속 권장.

---

## 6. 후속 TODO
- [x] APNS p8 주입 — `mochi-apns-p8-base64` Secret + svc `.env` (2026-06-08, EC 키 파싱 검증)
- [x] SSH 단독화 — 현 상태 유지로 결정 (§3: owner 3명은 mochi 무관 팀원, 강등 안 함)
- [x] Apple 로그인 운영 연결 — 백엔드 `AUTH_APPLE_*` 명시 + iOS Release baseURL (2026-06-08)
- [x] iOS Release baseURL → 배포 서버 (`AppDependencies.resolveBaseURL`, Debug 는 localhost/LAN 유지)
- [x] Google 로그인: `AUTH_GOOGLE_CLIENT_IDS` 주입 — svc `.env` append + `systemctl restart mochi` (2026-06-23). ⚠️ 재배포 시 `.env` 생성부에 포함 필요(공개 client id, Secret 불필요).
- [ ] db 데이터 디스크 분리 + 스냅샷 백업
- [ ] (선택) 운영 도메인 구입 → nip.io 대체
