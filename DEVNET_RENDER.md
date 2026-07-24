# ZAP public devnet

This setup creates a new Katana chain for public testing. It does not change the existing Sepolia world or the current Sepolia Torii service.

## 1. Deploy Katana

1. Commit and push `render.katana.yaml` and `Dockerfile.katana.render` from the `contracts` repository.
2. In Render, select **New** then **Blueprint** and choose this repository.
3. Select `render.katana.yaml` as the Blueprint file.
4. Create the `zapfc-devnet-katana` service. Keep the attached disk enabled.
5. Copy the public service URL after it becomes live. It is the devnet RPC URL.

Katana uses chain ID `ZAP_DEVNET`, free transactions, public CORS, persistent chain storage, and Cartridge controller/paymaster support.

### No-card temporary option

Use `render.katana.free.yaml` instead when a paid disk is not possible. It creates a free public Katana service without a persistent disk.

The service is suitable only for a temporary demo: every Render restart, redeploy, or loss of ephemeral storage resets the whole chain. After any reset, run the migration again, replace the frontend manifest with the new `manifest_dev.json`, and restart the devnet Torii service.

## 2. Migrate a fresh world

From `contracts/`, deploy the world to the new Katana URL:

```bash
sozo build
sozo migrate --rpc-url https://REPLACE_WITH_DEVNET_KATANA_URL --katana-account katana0 --wait
```

This writes the fresh world address and contract addresses to `contracts/manifest_dev.json`. It does not write to Sepolia.

Copy that generated manifest into the frontend:

```bash
cp manifest_dev.json ../frontend/src/lib/manifest_dev.json
```

## 3. Deploy a second Torii service

Do not edit the existing Sepolia Torii service. Create a second Render service from the same Torii image/configuration, using `torii_devnet.toml.example` as the config source.

Replace these two values before deployment:

- `REPLACE_WITH_DEVNET_WORLD_ADDRESS`: `world.address` from `manifest_dev.json`.
- `REPLACE_WITH_DEVNET_KATANA_URL`: the public Katana URL from step 1.

Start Torii with its HTTP address bound publicly and CORS enabled:

```bash
torii --world REPLACE_WITH_DEVNET_WORLD_ADDRESS --rpc https://REPLACE_WITH_DEVNET_KATANA_URL --http.addr 0.0.0.0 --http.cors_origins "*" --config torii_devnet.toml
```

Verify its GraphQL endpoint at `https://REPLACE_WITH_DEVNET_TORII_URL/graphql`.

## 4. Switch the frontend only after both services work

Copy `frontend/.env.devnet.example` to `frontend/.env.devnet` and replace the two URLs. Use those values in your frontend host's environment settings, then deploy a separate devnet frontend.

`VITE_ALLOW_KATANA_CONTROLLER=true` is required because this is a remote Katana chain. It allows the existing Cartridge Controller connector to use the devnet instead of forcing Sepolia.

## 5. Smoke test

1. Open the devnet frontend in two separate browser profiles.
2. Connect two different Cartridge accounts.
3. Create two clubs and confirm both registrations in the new Torii GraphQL endpoint.
4. Create and join a P2P room.
5. Play through one complete match.

Keep the current Sepolia frontend and Torii service unchanged until all five checks pass.
