Uniswap v4-core `src/` at commit 46c6834698c48bc4a463a86d8420f4eb1d7f3b75, copied verbatim from the IdentityMD plane's
vendored copy (Identity-md/protocol packages/contracts/lib/v4-core): the version v1's PegFeeHook
was built and audited against. src/ imports only interfaces, types and libraries; the unit tests also deploy
PoolManager locally (it needs lib/solmate's Owned), and the fork tests use the real mainnet PoolManager.
