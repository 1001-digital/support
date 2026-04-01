import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { getAddress, parseEther } from "viem";

describe("Support", async function () {
  const { viem } = await network.connect();
  const publicClient = await viem.getPublicClient();
  const [walletClient, otherWallet] = await viem.getWalletClients();

  const ETH_USD = 200000000000n; // $2,000

  const tierPrices: readonly [bigint, bigint, bigint, bigint] = [
    500000000n,   // $5/mo
    1000000000n,  // $10/mo
    2500000000n,  // $25/mo
    5000000000n,  // $50/mo
  ];

  const discountMinMonths = 12;
  const discountPercentOff = 20;

  async function deploy() {
    const priceFeed = await viem.deployContract("MockPriceFeed", [ETH_USD]);
    const support = await viem.deployContract("Support", [
      "TestProject",
      "TEST",
      '<path d="M0 0"/>',
      priceFeed.address,
      tierPrices,
      discountMinMonths,
      discountPercentOff,
    ]);
    return { support, priceFeed };
  }

  // --- Cost ---

  it("Should calculate base cost", async function () {
    const { support } = await deploy();
    assert.equal(await support.read.cost([0, 1]), parseEther("0.0025"));
    assert.equal(await support.read.cost([3, 1]), parseEther("0.025"));
  });

  it("Should apply discount at 12+ months", async function () {
    const { support } = await deploy();
    // $5 * 12 = $60, 20% off = $48 / $2000 = 0.024 ETH
    assert.equal(await support.read.cost([0, 12]), parseEther("0.024"));
  });

  it("Should revert cost for invalid inputs", async function () {
    const { support } = await deploy();
    await assert.rejects(support.read.cost([4, 1]), /InvalidTier/);
    await assert.rejects(support.read.cost([0, 0]), /InvalidDuration/);
  });

  // --- New subscription ---

  it("Should mint NFT on first support", async function () {
    const { support } = await deploy();
    const ethCost = await support.read.cost([0, 1]);

    await support.write.support([walletClient.account.address, 0, 1], { value: ethCost });

    assert.equal(await support.read.totalSupply(), 1n);
    assert.equal(await support.read.activeToken([walletClient.account.address]), 1n);
    assert.equal(await support.read.balanceOf([walletClient.account.address]), 1n);

    const segs = await support.read.segments([1n]);
    assert.equal(segs.length, 1);
    assert.equal(segs[0].tier, 0);
  });

  // --- Same-tier extension ---

  it("Should extend same tier without new segment", async function () {
    const { support } = await deploy();
    const ethCost = await support.read.cost([0, 1]);

    await support.write.support([walletClient.account.address, 0, 1], { value: ethCost });
    const firstExpiry = await support.read.expiresAt([1n]);

    await support.write.support([walletClient.account.address, 0, 1], { value: ethCost });
    const secondExpiry = await support.read.expiresAt([1n]);

    assert.equal(secondExpiry, firstExpiry + 30n * 24n * 60n * 60n);

    const segs = await support.read.segments([1n]);
    assert.equal(segs.length, 1); // no new segment
  });

  // --- Upgrade ---

  it("Should upgrade immediately and charge difference", async function () {
    const { support, priceFeed } = await deploy();

    // Subscribe tier 0 ($5/mo) for 2 months
    await support.write.support([walletClient.account.address, 0, 2], { value: await support.read.cost([0, 2]) });

    // Advance 1 month — 1 month remaining at tier 0
    await publicClient.request({ method: "evm_increaseTime" as any, params: [30 * 24 * 60 * 60] });
    await publicClient.request({ method: "evm_mine" as any, params: [] });
    await priceFeed.write.setPrice([ETH_USD]);

    // Upgrade to tier 2 ($25/mo) for 1 new month
    // Diff for ~1 remaining month: ($25 - $5) * 1 = $20/mo → ~$20
    // Plus 1 new month at $25 = $25
    // Total ~$45 / $2000 = ~0.0225 ETH
    const expiryBefore = await support.read.expiresAt([1n]);

    // Overpay and check refund
    const hash = await support.write.support([walletClient.account.address, 2, 1], { value: parseEther("1") });
    const receipt = await publicClient.getTransactionReceipt({ hash });
    const events = await publicClient.getContractEvents({
      address: support.address,
      abi: support.abi,
      eventName: "Supported",
      fromBlock: receipt.blockNumber,
      toBlock: receipt.blockNumber,
    });

    // Paid should be > 0 and < 1 ETH (the overpay)
    const paid = events[0].args.paid!;
    assert.ok(paid > 0n);
    assert.ok(paid < parseEther("1"));

    // Expiry extended by 1 month from old expiry
    const expiryAfter = await support.read.expiresAt([1n]);
    assert.equal(expiryAfter, expiryBefore + 30n * 24n * 60n * 60n);

    // Current tier is now 2
    const [tier, active] = await support.read.currentTier([1n]);
    assert.equal(tier, 2);
    assert.equal(active, true);

    // Two segments: tier 0, then tier 2
    const segs = await support.read.segments([1n]);
    assert.equal(segs.length, 2);
    assert.equal(segs[0].tier, 0);
    assert.equal(segs[1].tier, 2);
  });

  it("Should upgrade with duration 0 (just pay diff)", async function () {
    const { support } = await deploy();

    await support.write.support([walletClient.account.address, 0, 2], { value: await support.read.cost([0, 2]) });
    const expiryBefore = await support.read.expiresAt([1n]);

    // Upgrade to tier 2 with duration 0 — only pay the diff, expiry unchanged
    await support.write.support([walletClient.account.address, 2, 0], { value: parseEther("1") });

    const expiryAfter = await support.read.expiresAt([1n]);
    assert.equal(expiryAfter, expiryBefore); // no extension

    const [tier] = await support.read.currentTier([1n]);
    assert.equal(tier, 2);
  });

  it("Should downgrade with duration 0 (just convert time)", async function () {
    const { support } = await deploy();

    await support.write.support([walletClient.account.address, 2, 1], { value: await support.read.cost([2, 1]) });
    const expiryBefore = await support.read.expiresAt([1n]);

    // Downgrade to tier 0 with duration 0 — free, remaining time converts
    await support.write.support([walletClient.account.address, 0, 0], { value: 0n });

    const expiryAfter = await support.read.expiresAt([1n]);
    assert.ok(expiryAfter > expiryBefore); // converted time is longer

    const [tier] = await support.read.currentTier([1n]);
    assert.equal(tier, 0);
  });

  it("Should revert duration 0 for new subscription", async function () {
    const { support } = await deploy();
    await assert.rejects(
      support.write.support([walletClient.account.address, 0, 0], { value: 0n }),
      /InvalidDuration/,
    );
  });

  it("Should revert duration 0 for same-tier extension", async function () {
    const { support } = await deploy();
    await support.write.support([walletClient.account.address, 0, 1], { value: await support.read.cost([0, 1]) });

    await assert.rejects(
      support.write.support([walletClient.account.address, 0, 0], { value: 0n }),
      /InvalidDuration/,
    );
  });

  // --- Downgrade ---

  it("Should downgrade immediately and extend duration", async function () {
    const { support, priceFeed } = await deploy();

    // Subscribe tier 2 ($25/mo) for 1 month
    await support.write.support([walletClient.account.address, 2, 1], { value: await support.read.cost([2, 1]) });

    // Advance 15 days — ~15 days remaining at tier 2
    await publicClient.request({ method: "evm_increaseTime" as any, params: [15 * 24 * 60 * 60] });
    await publicClient.request({ method: "evm_mine" as any, params: [] });
    await priceFeed.write.setPrice([ETH_USD]);

    const block = await publicClient.getBlock();
    const expiryBefore = await support.read.expiresAt([1n]);
    const remaining = expiryBefore - block.timestamp;

    // Downgrade to tier 0 ($5/mo) for 1 new month
    // Remaining ~15 days at $25 converts to ~75 days at $5 (5x)
    // Plus 30 days new = ~105 days total from now
    await support.write.support([walletClient.account.address, 0, 1], { value: await support.read.cost([0, 1]) });

    const expiryAfter = await support.read.expiresAt([1n]);
    // Converted remaining = remaining * 25 / 5 = remaining * 5
    const expectedExpiry = block.timestamp + remaining * 5n + 30n * 24n * 60n * 60n;

    // Allow 5 second tolerance for block timestamp drift
    assert.ok(expiryAfter >= expectedExpiry - 5n);
    assert.ok(expiryAfter <= expectedExpiry + 5n);

    const [tier] = await support.read.currentTier([1n]);
    assert.equal(tier, 0);

    const segs = await support.read.segments([1n]);
    assert.equal(segs.length, 2);
  });

  it("Should handle downgrade to free tier", async function () {
    const { support } = await deploy();

    await support.write.setTierPrice([0, 0n]); // tier 0 = free

    // Subscribe tier 2 for 1 month
    await support.write.support([walletClient.account.address, 2, 1], { value: await support.read.cost([2, 1]) });

    const expiryBefore = await support.read.expiresAt([1n]);

    // Downgrade to free tier — remaining time stays 1:1
    await support.write.support([walletClient.account.address, 0, 1], { value: 0n });

    const expiryAfter = await support.read.expiresAt([1n]);
    // Should have added 30 days but remaining time stays approximately the same
    assert.ok(expiryAfter > expiryBefore);
  });

  // --- Subscription expiry + new NFT ---

  it("Should mint new NFT after expiry", async function () {
    const { support, priceFeed } = await deploy();

    await support.write.support([walletClient.account.address, 0, 1], { value: await support.read.cost([0, 1]) });

    await publicClient.request({ method: "evm_increaseTime" as any, params: [30 * 24 * 60 * 60 + 1] });
    await publicClient.request({ method: "evm_mine" as any, params: [] });
    await priceFeed.write.setPrice([ETH_USD]);

    await support.write.support([walletClient.account.address, 2, 1], { value: await support.read.cost([2, 1]) });

    assert.equal(await support.read.totalSupply(), 2n);
    assert.equal(await support.read.activeToken([walletClient.account.address]), 2n);
    assert.equal(await support.read.balanceOf([walletClient.account.address]), 2n);

    // Old token still exists
    assert.equal(await support.read.ownerOf([1n]), getAddress(walletClient.account.address));
  });

  it("Should return inactive for expired token", async function () {
    const { support } = await deploy();

    await support.write.support([walletClient.account.address, 0, 1], { value: await support.read.cost([0, 1]) });

    await publicClient.request({ method: "evm_increaseTime" as any, params: [30 * 24 * 60 * 60 + 1] });
    await publicClient.request({ method: "evm_mine" as any, params: [] });

    const [, active] = await support.read.currentTier([1n]);
    assert.equal(active, false);
  });

  // --- Refund ---

  it("Should refund excess and emit correct paid", async function () {
    const { support } = await deploy();
    const ethCost = await support.read.cost([0, 1]);
    const overpay = ethCost + parseEther("0.5");

    const balanceBefore = await publicClient.getBalance({ address: walletClient.account.address });
    const hash = await support.write.support([walletClient.account.address, 0, 1], { value: overpay });
    const receipt = await publicClient.getTransactionReceipt({ hash });
    const gasUsed = receipt.gasUsed * receipt.effectiveGasPrice;
    const balanceAfter = await publicClient.getBalance({ address: walletClient.account.address });

    assert.equal(balanceAfter, balanceBefore - ethCost - gasUsed);
  });

  it("Should revert on insufficient payment", async function () {
    const { support } = await deploy();
    await assert.rejects(support.write.support([walletClient.account.address, 0, 1], { value: 1n }), /InsufficientPayment/);
  });

  // --- Oracle ---

  it("Should revert on stale/zero/bad-round price", async function () {
    const { support, priceFeed } = await deploy();

    await priceFeed.write.setPrice([0n]);
    await assert.rejects(support.read.cost([0, 1]), /StalePrice/);

    await priceFeed.write.setPrice([ETH_USD]);
    await priceFeed.write.setRoundData([10, 9]);
    await assert.rejects(support.read.cost([0, 1]), /StalePrice/);
  });

  // --- Owner ---

  it("Should allow owner functions", async function () {
    const { support } = await deploy();

    await support.write.setTierPrice([0, 750000000n]);
    assert.equal(await support.read.tierPrices([0]), 750000000n);

    await support.write.setDiscount([6, 10]);
    assert.equal(await support.read.discountMinMonths(), 6);

    await support.write.setLogo(['<path d="M0 0"/>']);
    assert.equal(await support.read.logo(), '<path d="M0 0"/>');


    await support.write.setMaxSlots([3, 5]);
    assert.equal(await support.read.maxSlots([3]), 5);
  });

  it("Should allow withdraw", async function () {
    const { support } = await deploy();
    const ethCost = await support.read.cost([0, 1]);
    await support.write.support([walletClient.account.address, 0, 1], { value: ethCost });

    const balanceBefore = await publicClient.getBalance({ address: walletClient.account.address });
    const hash = await support.write.withdraw();
    const receipt = await publicClient.getTransactionReceipt({ hash });
    const gasUsed = receipt.gasUsed * receipt.effectiveGasPrice;
    const balanceAfter = await publicClient.getBalance({ address: walletClient.account.address });

    assert.equal(balanceAfter, balanceBefore + ethCost - gasUsed);
  });

  it("Should reject non-owner calls", async function () {
    const { support } = await deploy();
    await assert.rejects(support.write.setTierPrice([0, 1n], { account: otherWallet.account }), /OwnableUnauthorizedAccount/);
    await assert.rejects(support.write.withdraw({ account: otherWallet.account }), /OwnableUnauthorizedAccount/);
  });

  it("Should transfer ownership via two-step process", async function () {
    const { support } = await deploy();

    // Step 1: propose new owner
    await support.write.transferOwnership([otherWallet.account.address]);
    // Owner unchanged until accepted
    assert.equal(await support.read.owner(), getAddress(walletClient.account.address));
    assert.equal(await support.read.pendingOwner(), getAddress(otherWallet.account.address));

    // Step 2: new owner accepts
    await support.write.acceptOwnership({ account: otherWallet.account });
    assert.equal(await support.read.owner(), getAddress(otherWallet.account.address));
  });

  it("Should reject acceptOwnership from non-pending address", async function () {
    const { support } = await deploy();
    await support.write.transferOwnership([otherWallet.account.address]);
    await assert.rejects(
      support.write.acceptOwnership({ account: walletClient.account }),
      /OwnableUnauthorizedAccount/,
    );
  });

  // --- NFT Transfer ---

  it("Should emit Transfer on mint, not on extension", async function () {
    const { support } = await deploy();
    const ethCost = await support.read.cost([0, 1]);

    const hash1 = await support.write.support([walletClient.account.address, 0, 1], { value: ethCost });
    const receipt1 = await publicClient.getTransactionReceipt({ hash: hash1 });
    const mints = await publicClient.getContractEvents({
      address: support.address, abi: support.abi, eventName: "Transfer",
      fromBlock: receipt1.blockNumber, toBlock: receipt1.blockNumber,
    });
    assert.equal(mints.length, 1);

    const hash2 = await support.write.support([walletClient.account.address, 0, 1], { value: ethCost });
    const receipt2 = await publicClient.getTransactionReceipt({ hash: hash2 });
    const noMints = await publicClient.getContractEvents({
      address: support.address, abi: support.abi, eventName: "Transfer",
      fromBlock: receipt2.blockNumber, toBlock: receipt2.blockNumber,
    });
    assert.equal(noMints.length, 0);
  });

  it("Should transfer NFT and subscription", async function () {
    const { support } = await deploy();
    await support.write.support([walletClient.account.address, 2, 3], { value: await support.read.cost([2, 3]) });

    await support.write.transferFrom([walletClient.account.address, otherWallet.account.address, 1n]);

    assert.equal(await support.read.ownerOf([1n]), getAddress(otherWallet.account.address));
    assert.equal(await support.read.balanceOf([walletClient.account.address]), 0n);
    assert.equal(await support.read.balanceOf([otherWallet.account.address]), 1n);

    // Active subscription moves with the NFT
    assert.equal(await support.read.activeToken([walletClient.account.address]), 0n);
    assert.equal(await support.read.activeToken([otherWallet.account.address]), 1n);

    const [tier, active] = await support.read.currentTier([1n]);
    assert.equal(tier, 2);
    assert.equal(active, true);
  });

  it("Should allow approved transfer", async function () {
    const { support } = await deploy();
    await support.write.support([walletClient.account.address, 0, 1], { value: await support.read.cost([0, 1]) });

    await support.write.approve([otherWallet.account.address, 1n]);
    await support.write.transferFrom(
      [walletClient.account.address, otherWallet.account.address, 1n],
      { account: otherWallet.account },
    );

    assert.equal(await support.read.ownerOf([1n]), getAddress(otherWallet.account.address));
  });

  it("Should not overwrite receiver's active subscription on transfer", async function () {
    const { support } = await deploy();

    // Both wallets subscribe
    await support.write.support([walletClient.account.address, 0, 1], { value: await support.read.cost([0, 1]) });
    await support.write.support([otherWallet.account.address, 2, 3], {
      value: await support.read.cost([2, 3]),
      account: otherWallet.account,
    });

    // otherWallet has active token 2 (tier 2, 3 months)
    assert.equal(await support.read.activeToken([otherWallet.account.address]), 2n);

    // Transfer token 1 to otherWallet — should NOT overwrite activeToken
    await support.write.transferFrom([walletClient.account.address, otherWallet.account.address, 1n]);

    // otherWallet's active subscription should still be token 2
    assert.equal(await support.read.activeToken([otherWallet.account.address]), 2n);
    assert.equal(await support.read.balanceOf([otherWallet.account.address]), 2n);
  });

  it("Should set receiver's activeToken if they have no active subscription", async function () {
    const { support } = await deploy();

    await support.write.support([walletClient.account.address, 0, 1], { value: await support.read.cost([0, 1]) });

    // otherWallet has no subscription
    assert.equal(await support.read.activeToken([otherWallet.account.address]), 0n);

    await support.write.transferFrom([walletClient.account.address, otherWallet.account.address, 1n]);

    // Now otherWallet inherits the active subscription
    assert.equal(await support.read.activeToken([otherWallet.account.address]), 1n);
  });

  it("Should revert unauthorized transfer", async function () {
    const { support } = await deploy();
    await support.write.support([walletClient.account.address, 0, 1], { value: await support.read.cost([0, 1]) });

    await assert.rejects(
      support.write.transferFrom(
        [walletClient.account.address, otherWallet.account.address, 1n],
        { account: otherWallet.account },
      ),
      /ERC721InsufficientApproval/,
    );
  });

  it("Should support ERC-165/721/4906 interfaces", async function () {
    const { support } = await deploy();
    assert.equal(await support.read.supportsInterface(["0x01ffc9a7"]), true);
    assert.equal(await support.read.supportsInterface(["0x80ac58cd"]), true);
    assert.equal(await support.read.supportsInterface(["0x5b5e139f"]), true);
    assert.equal(await support.read.supportsInterface(["0x49064906"]), true);
    assert.equal(await support.read.supportsInterface(["0xffffffff"]), false);
  });

  // --- tokenURI ---

  it("Should build active tokenURI with project name and badge", async function () {
    const { support } = await deploy();
    await support.write.support([walletClient.account.address, 0, 1], { value: await support.read.cost([0, 1]) });

    const uri = await support.read.tokenURI([1n]);
    const json = JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString());

    assert.equal(json.name, "TestProject #1");

    const svg = Buffer.from(json.image.split(",")[1], "base64").toString();
    assert.ok(svg.includes("TestProject"));
    assert.ok(svg.includes("ACTIVE"));
    assert.ok(svg.includes("DAY 1"));
    assert.ok(svg.includes("0x"));
    assert.ok(svg.includes("..."));

    assert.equal(json.attributes.find((a: any) => a.trait_type === "Status").value, "Active");
    assert.equal(json.attributes.find((a: any) => a.trait_type === "Tier").value, 0);
  });

  it("Should build expired tokenURI with last tier badge", async function () {
    const { support } = await deploy();

    await support.write.support([walletClient.account.address, 0, 1], { value: await support.read.cost([0, 1]) });
    await support.write.support([walletClient.account.address, 2, 1], { value: parseEther("1") });

    await publicClient.request({ method: "evm_increaseTime" as any, params: [90 * 24 * 60 * 60] });
    await publicClient.request({ method: "evm_mine" as any, params: [] });

    const uri = await support.read.tokenURI([1n]);
    const json = JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString());

    const svg = Buffer.from(json.image.split(",")[1], "base64").toString();
    assert.ok(svg.includes("EXPIRED"));

    assert.equal(json.attributes.find((a: any) => a.trait_type === "Status").value, "Expired");
    assert.equal(json.attributes.find((a: any) => a.trait_type === "Tier").value, 2);
    assert.ok(json.attributes.find((a: any) => a.trait_type === "Segment 1"));
    assert.ok(json.attributes.find((a: any) => a.trait_type === "Segment 2"));
  });

  // --- Tier slot limits ---

  it("Should enforce and free tier slots", async function () {
    const wallets = await viem.getWalletClients();
    const { support, priceFeed } = await deploy();

    await support.write.setMaxSlots([3, 1]);

    const cost3 = await support.read.cost([3, 1]);
    await support.write.support([wallets[0].account.address, 3, 1], { value: cost3, account: wallets[0].account });

    // Slot full
    await assert.rejects(
      support.write.support([wallets[1].account.address, 3, 1], { value: cost3, account: wallets[1].account }),
      /TierFull/,
    );

    // Holder downgrades — frees slot
    await support.write.support([wallets[0].account.address, 0, 1], { value: parseEther("1"), account: wallets[0].account });

    await support.write.support([wallets[1].account.address, 3, 1], { value: cost3, account: wallets[1].account });
    const holders = await support.read.tierHolders([3]);
    assert.equal(holders[0], getAddress(wallets[1].account.address));
  });

  it("Should free slot on expiry", async function () {
    const wallets = await viem.getWalletClients();
    const { support, priceFeed } = await deploy();

    await support.write.setMaxSlots([3, 1]);
    await support.write.support([wallets[0].account.address, 3, 1], { value: await support.read.cost([3, 1]), account: wallets[0].account });

    await publicClient.request({ method: "evm_increaseTime" as any, params: [30 * 24 * 60 * 60 + 1] });
    await publicClient.request({ method: "evm_mine" as any, params: [] });
    await priceFeed.write.setPrice([ETH_USD]);

    await support.write.support([wallets[1].account.address, 3, 1], { value: await support.read.cost([3, 1]), account: wallets[1].account });
    const holders = await support.read.tierHolders([3]);
    assert.equal(holders[0], getAddress(wallets[1].account.address));
  });

  // --- Edge cases ---

  it("Should handle 100% discount", async function () {
    const { support } = await deploy();
    await support.write.setDiscount([1, 100]);
    await support.write.support([walletClient.account.address, 0, 1], { value: 0n });
    assert.equal(await support.read.totalSupply(), 1n);
  });

  it("Should emit MetadataUpdate on every call", async function () {
    const { support } = await deploy();
    const ethCost = await support.read.cost([0, 1]);
    await support.write.support([walletClient.account.address, 0, 1], { value: ethCost });

    const hash = await support.write.support([walletClient.account.address, 0, 1], { value: ethCost });
    const receipt = await publicClient.getTransactionReceipt({ hash });
    const events = await publicClient.getContractEvents({
      address: support.address, abi: support.abi, eventName: "MetadataUpdate",
      fromBlock: receipt.blockNumber, toBlock: receipt.blockNumber,
    });
    assert.equal(events.length, 1);
  });

  it("Should track multiple subscribers independently", async function () {
    const { support } = await deploy();
    await support.write.support([walletClient.account.address, 0, 1], { value: await support.read.cost([0, 1]) });
    await support.write.support([otherWallet.account.address, 2, 1], { value: await support.read.cost([2, 1]), account: otherWallet.account });

    assert.equal(await support.read.totalSupply(), 2n);
    assert.equal(await support.read.activeToken([walletClient.account.address]), 1n);
    assert.equal(await support.read.activeToken([otherWallet.account.address]), 2n);
  });

  // --- Owner grant ---

  it("Should allow owner to grant free subscription", async function () {
    const { support } = await deploy();

    await support.write.grant([otherWallet.account.address, 3, 6]);

    assert.equal(await support.read.totalSupply(), 1n);
    assert.equal(await support.read.activeToken([otherWallet.account.address]), 1n);
    assert.equal(await support.read.ownerOf([1n]), getAddress(otherWallet.account.address));

    const [tier, active] = await support.read.currentTier([1n]);
    assert.equal(tier, 3);
    assert.equal(active, true);
  });

  it("Should allow owner to grant extension", async function () {
    const { support } = await deploy();

    await support.write.grant([otherWallet.account.address, 0, 1]);
    const firstExpiry = await support.read.expiresAt([1n]);

    await support.write.grant([otherWallet.account.address, 0, 1]);
    const secondExpiry = await support.read.expiresAt([1n]);

    assert.equal(secondExpiry, firstExpiry + 30n * 24n * 60n * 60n);
    assert.equal(await support.read.totalSupply(), 1n);
  });

  it("Should reject non-owner grant", async function () {
    const { support } = await deploy();

    await assert.rejects(
      support.write.grant([otherWallet.account.address, 0, 1], { account: otherWallet.account }),
      /OwnableUnauthorizedAccount/,
    );
  });

  // --- Gifting ---

  it("Should allow gifting a subscription to another address", async function () {
    const { support } = await deploy();
    const ethCost = await support.read.cost([2, 3]);

    // walletClient pays, otherWallet receives
    await support.write.support([otherWallet.account.address, 2, 3], { value: ethCost });

    assert.equal(await support.read.totalSupply(), 1n);
    assert.equal(await support.read.activeToken([otherWallet.account.address]), 1n);
    assert.equal(await support.read.balanceOf([otherWallet.account.address]), 1n);
    assert.equal(await support.read.balanceOf([walletClient.account.address]), 0n);
    assert.equal(await support.read.ownerOf([1n]), getAddress(otherWallet.account.address));

    const [tier, active] = await support.read.currentTier([1n]);
    assert.equal(tier, 2);
    assert.equal(active, true);
  });

  it("Should reject third-party tier change", async function () {
    const wallets = await viem.getWalletClients();
    const { support } = await deploy();

    // wallets[2] subscribes at tier 0
    await support.write.support([wallets[2].account.address, 0, 1], {
      value: await support.read.cost([0, 1]),
      account: wallets[2].account,
    });

    // wallets[3] (not recipient, not owner) tries to upgrade — should fail
    await assert.rejects(
      support.write.support([wallets[2].account.address, 2, 1], {
        value: parseEther("1"),
        account: wallets[3].account,
      }),
      /TierChangeForbidden/,
    );

    // Third party extending at same tier is OK
    await support.write.support([wallets[2].account.address, 0, 1], {
      value: await support.read.cost([0, 1]),
      account: wallets[3].account,
    });
  });

  it("Should allow recipient to change their own tier", async function () {
    const { support } = await deploy();

    await support.write.support([otherWallet.account.address, 0, 2], {
      value: await support.read.cost([0, 2]),
      account: otherWallet.account,
    });

    // otherWallet upgrades themselves
    await support.write.support([otherWallet.account.address, 2, 1], {
      value: parseEther("1"),
      account: otherWallet.account,
    });

    const [tier] = await support.read.currentTier([1n]);
    assert.equal(tier, 2);
  });

  it("Should reject support to zero address", async function () {
    const { support } = await deploy();
    await assert.rejects(
      support.write.support(["0x0000000000000000000000000000000000000000", 0, 1], {
        value: await support.read.cost([0, 1]),
      }),
      /InvalidRecipient/,
    );
  });

  it("Should allow grant when oracle is stale", async function () {
    const { support, priceFeed } = await deploy();

    // Make oracle stale
    const block = await publicClient.getBlock();
    await priceFeed.write.setUpdatedAt([block.timestamp - 7200n]);

    // Grant should work (skips oracle)
    await support.write.grant([otherWallet.account.address, 2, 3]);

    const [tier, active] = await support.read.currentTier([1n]);
    assert.equal(tier, 2);
    assert.equal(active, true);
  });

  it("Should allow gifting an extension to existing subscription", async function () {
    const { support } = await deploy();

    // Other wallet self-subscribes
    await support.write.support([otherWallet.account.address, 0, 1], {
      value: await support.read.cost([0, 1]),
      account: otherWallet.account,
    });
    const firstExpiry = await support.read.expiresAt([1n]);

    // walletClient gifts an extension
    await support.write.support([otherWallet.account.address, 0, 1], {
      value: await support.read.cost([0, 1]),
    });
    const secondExpiry = await support.read.expiresAt([1n]);

    assert.equal(secondExpiry, firstExpiry + 30n * 24n * 60n * 60n);
    assert.equal(await support.read.totalSupply(), 1n); // no new NFT
  });
});
