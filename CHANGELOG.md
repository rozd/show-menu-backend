# Changelog

## [0.2.0](https://github.com/rozd/show-menu-backend/compare/v0.1.0...v0.2.0) (2026-11-07)


### ⚠ BREAKING CHANGES

* **api:** root /health, /version and POST / moved under /api/v1; missing or ill-typed request fields are 400 (was 422); Currency symbol/base/digits are omitted when absent instead of null; Echo removed.

### Features

* **accounts:** link account to creator and grant owner permission ([0dca7a8](https://github.com/rozd/show-menu-backend/commit/0dca7a84d43989c7e06f3389d9b1d9c0bd53473a))
* **api:** serve the HTTP API from the show-menu-contracts OpenAPI spec ([#19](https://github.com/rozd/show-menu-backend/issues/19)) ([734c1a7](https://github.com/rozd/show-menu-backend/commit/734c1a7dc5b91d0317f99b1a857e4b573a5a27ce))
* **app:** error envelope middleware and shared kernel ([e7f8ef6](https://github.com/rozd/show-menu-backend/commit/e7f8ef61c6295ed20f1699c0f861834289f9f9f7))
* **app:** local loop, /api prefix, Echo module, CI ([1a84a81](https://github.com/rozd/show-menu-backend/commit/1a84a817714fb4ad88a27a48f44121ca9f27d675))
* **auth:** firebase id-token verifier and admin guard ([5b2c8dc](https://github.com/rozd/show-menu-backend/commit/5b2c8dc1fb87a685509124a758a3405e5443d18a))
* **auth:** SchedulerAuthMiddleware for Cloud Scheduler jobs (OIDC or X-Api-Key) ([98f58ae](https://github.com/rozd/show-menu-backend/commit/98f58ae6209c33f2c4d877ed2b4a56880f20ea19))
* **catalog:** Feature aggregate with create/update endpoints ([48db3ce](https://github.com/rozd/show-menu-backend/commit/48db3ce94d0d004127734526cf2b445a7c171994))
* **catalog:** Plan aggregate with create/get/list endpoints ([914e250](https://github.com/rozd/show-menu-backend/commit/914e250fed0f529238c4071e521456da745bf98f))
* **catalog:** plan mutations (update, activate, deactivate, add/remove feature) ([c49daf9](https://github.com/rozd/show-menu-backend/commit/c49daf98103a8d4fadd9c36a7b996652283f7b89))
* **cloud-functions:** firestore-forwarder for accounts/{id} create ([1e8d129](https://github.com/rozd/show-menu-backend/commit/1e8d1299943953de8869ddf85470eda3c7680738))
* **config:** enable CORS when running against the Firebase emulator ([06e145a](https://github.com/rozd/show-menu-backend/commit/06e145a18193a24c3543e3e6670b3afdd422f46e))
* **echo:** answer every verb on hello/echo/version and port /echo/echo ([a6ab1de](https://github.com/rozd/show-menu-backend/commit/a6ab1de181fbf233fed4ecf840103b116998857a))
* **iam:** users/{uid} Node schema, onboarding for all users, OIDC-guarded webhook ([f473278](https://github.com/rozd/show-menu-backend/commit/f4732786e95d97daabc44dfc112747e116e5c1be))
* **identity-blocking:** grant admin claim to verified ADMIN_EMAILS ([5e55c0d](https://github.com/rozd/show-menu-backend/commit/5e55c0d12dfdfd3f284dbcee5b3c8dc1590f7c6a))
* **liqpay:** LiqPay payment gateway ported from fitnessart ([9d70e6c](https://github.com/rozd/show-menu-backend/commit/9d70e6c43d43d88f87e87b790c7dfcb3a0b0232d))
* **purchases:** cancel purchase endpoint loading the order via the invoice and cancelling invoice, order and session in one transaction ([0ddb419](https://github.com/rozd/show-menu-backend/commit/0ddb4198fcc9300880c4dd914ac5ee2df78968d9))
* **purchases:** LiqPay callback endpoint applying payment status to invoice, order and session in one inboxed transaction ([f0018bd](https://github.com/rozd/show-menu-backend/commit/f0018bdb5d0915d20232312c2dbc08ef98cf65d9))
* **purchases:** Order and Invoice aggregates, Firestore models, mappers and repositories ([b256ed5](https://github.com/rozd/show-menu-backend/commit/b256ed5df04c1eaee597840dfddd7f2ecdfce1c8))
* **purchases:** purchase subscription endpoint with account membership check and checkout initiation ([2710652](https://github.com/rozd/show-menu-backend/commit/2710652962a43c44b82d8e22e8e8a6a08a4abe23))
* streamline local dev setup and clarify project structure ([9f9702c](https://github.com/rozd/show-menu-backend/commit/9f9702c216b98023bc998c4fc53c2b246e24b1a5))
* **subscriptions:** daily expiration job with reconcile pass ([b241bbf](https://github.com/rozd/show-menu-backend/commit/b241bbf75866ff4c8b8cb1b542fe71bbd8a69dc9))
* **subscriptions:** subscription lifecycle driven by invoice events ([3daf2ff](https://github.com/rozd/show-menu-backend/commit/3daf2ff1e9a4e527cad787333bbe84c6b059b8e7))


### Bug Fixes

* **accounts:** make missing account a no-op in link/grant; link reads stored creator ([20f9698](https://github.com/rozd/show-menu-backend/commit/20f9698b0e1e79b4bb61695c8bed1fdc4adae53b))
* **app:** keep trace middleware ahead of the error envelope ([d796d76](https://github.com/rozd/show-menu-backend/commit/d796d76555debe5ba2a192f20f941c7965226f91))
* **auth:** guard unmatched /plans paths for every HTTP method ([e4b70bf](https://github.com/rozd/show-menu-backend/commit/e4b70bf40bf1c675765b8c8ed6a19b95a1649f1b))
* **auth:** harden JWKS handling and token checks ([df93279](https://github.com/rozd/show-menu-backend/commit/df93279d32a08bb4cdb9f31a154a3acf060d3a59))
* **auth:** require a verified email for allow-listed OIDC service accounts ([118bb4a](https://github.com/rozd/show-menu-backend/commit/118bb4aa71132885f672491cc9bafa97669916f8))
* **catalog:** non-transactional SKU lookup; docs(migration): complete S05 ([a1abc41](https://github.com/rozd/show-menu-backend/commit/a1abc41a2a2d10f38c9d018b4b1e8a7bdb0936be))
* **catalog:** race-free SKU uniqueness via marker doc; Node-matching numeric kinds ([14d0f01](https://github.com/rozd/show-menu-backend/commit/14d0f0105e1ee044439c31353b2ffc3f5383b385))
* **firestore:** let write-less transactions commit against the emulator ([9820df0](https://github.com/rozd/show-menu-backend/commit/9820df03f0d1dffe79bc7426b44d254639f9e5f7))
* **firestore:** millisecond-precise Timestamp(exact:) like Node's Timestamp.fromDate ([f3544f7](https://github.com/rozd/show-menu-backend/commit/f3544f72b9b72f3d8a147ec66299a4ba7152c61b))
* **firestore:** retry transactions only on transient Firestore failures ([f609336](https://github.com/rozd/show-menu-backend/commit/f60933698f3c1124b62e3aac30926f2e292b8c10))
* **purchases,subscriptions:** match Node status codes for harness parity ([73b4c7e](https://github.com/rozd/show-menu-backend/commit/73b4c7e5366f126d5c1b11c1c9e433a702ffc41c))
* **purchases:** acknowledge callbacks whose order_id is not an invoice id ([2d481b3](https://github.com/rozd/show-menu-backend/commit/2d481b305717835d78bbd130a2605c566fb2416c))
* **purchases:** ignore a late failure callback for the payment already applied ([9937ce8](https://github.com/rozd/show-menu-backend/commit/9937ce8f158fe4e3036b4bf3cd05f146246a9998))
* **purchases:** surface the gateway error even if recording the failure fails ([088fa5e](https://github.com/rozd/show-menu-backend/commit/088fa5e16f47326ca48db8285d712ecf7a840e7b))
* **subscriptions:** stop scheduler auth middleware masking job errors as 401 ([b249fdc](https://github.com/rozd/show-menu-backend/commit/b249fdcf5b96d4330216ac02715d113778640b47))
