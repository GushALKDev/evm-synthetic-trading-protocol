#!/usr/bin/env python3
"""Age of on-chain Pyth updates when they are included in a block.

Samples PriceFeedUpdate events of a Pyth contract over several block windows and prints, for each event,
block.timestamp - publishTime. Used to choose PythChainlinkOracle.maxPriceAge and to check whether a
publishTime after block.timestamp occurs (docs/03-architecture.md, section 2).

The events come from price pushers (bots), so the ages describe their latency, not a wallet user's.

Usage (read-only JSON-RPC; the RPC must allow eth_getLogs over --window blocks):
    python3 script/analysis/pyth_update_age.py --rpc https://arb1.arbitrum.io/rpc \\
        --head 509770836 --window 10000 --step 86400 --count 60
"""

import argparse
import collections
import json
import time
import urllib.error
import urllib.request

PYTH_ARBITRUM_ONE = "0xff1a0f4744e8582DF1aE09D5611b887B6a12925C"
# keccak256("PriceFeedUpdate(bytes32,uint64,int64,uint64)")
PRICE_FEED_UPDATE = "0xd06a6b7f4918494b3719217d1802786c1f5112a6c1d88fe2cfec00b4584f6aec"


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    headers = {"Content-Type": "application/json", "User-Agent": "pyth-update-age"}
    for attempt in range(8):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers), timeout=60) as resp:
                out = json.loads(resp.read())
            if "error" in out:
                raise RuntimeError(out["error"])
            return out["result"]
        except urllib.error.HTTPError as err:
            if err.code != 429:
                raise
            time.sleep(2**attempt)
    raise RuntimeError("rate limited")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--pyth", default=PYTH_ARBITRUM_ONE)
    parser.add_argument("--head", type=int, help="last block of the first window (default: latest)")
    parser.add_argument("--window", type=int, default=10000, help="blocks per window")
    parser.add_argument("--step", type=int, default=86400, help="blocks between window ends")
    parser.add_argument("--count", type=int, default=60, help="number of windows")
    args = parser.parse_args()

    head = args.head if args.head is not None else int(rpc(args.rpc, "eth_blockNumber", []), 16)
    timestamps = {}
    ages = []
    txs = set()
    feeds = set()
    for k in range(args.count):
        to_block = head - k * args.step
        from_block = to_block - args.window
        logs = rpc(args.rpc, "eth_getLogs", [{"fromBlock": hex(from_block), "toBlock": hex(to_block), "address": args.pyth, "topics": [PRICE_FEED_UPDATE]}])
        for log in logs:
            block = int(log["blockNumber"], 16)
            if block not in timestamps:
                timestamps[block] = int(rpc(args.rpc, "eth_getBlockByNumber", [hex(block), False])["timestamp"], 16)
            publish_time = int(log["data"][2:66], 16)
            ages.append(timestamps[block] - publish_time)
            txs.add(log["transactionHash"])
            feeds.add(log["topics"][1])

    print(f"head block {head}, {args.count} windows of {args.window} blocks, {args.step} blocks apart")
    print(f"events {len(ages)}, distinct transactions {len(txs)}, distinct feeds {len(feeds)}")
    print(f"age at inclusion in seconds (age: events): {dict(sorted(collections.Counter(ages).items()))}")
    print(f"publishTime after block.timestamp: {sum(1 for a in ages if a < 0)}")


if __name__ == "__main__":
    main()
