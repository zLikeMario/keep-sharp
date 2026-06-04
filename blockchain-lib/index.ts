import axios from "axios";
import uniswapV3 from "./uniswapV3.ts";
import { createPublicClient, encodeEventTopics, getContract, http } from "viem";
import { bsc } from "viem/chains";
import { fetch as undiciFetch, ProxyAgent } from "undici";

const rpcUrl = "https://bsc-dataseed1.ninicoin.io";
const proxyUrl = process.env.HTTPS_PROXY ?? process.env.HTTP_PROXY;
const proxyAgent = proxyUrl ? new ProxyAgent(proxyUrl) : undefined;

// const transport = proxyAgent
//   ? http(rpcUrl, {
//       fetchFn: (url, init) => undiciFetch(url, { ...init, dispatcher: proxyAgent }),
//     })
//   : http(rpcUrl);

// const contract = getContract({
//   address: "0xFBA3912Ca04dd458c843e2EE08967fC04f3579c2",
//   abi: uniswapV3,
//   // 1a. Insert a single client
//   client: createPublicClient({
//     chain: bsc,
//     transport,
//   }),
// });

// const logs = await contract.getEvents.Swap({}, { fromBlock: 0, toBlock: "" });
// console.log(logs.length);

const topics = encodeEventTopics({
  abi: uniswapV3,
  eventName: "Swap",
  args: {
    sender: "0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af",
    recipient: "0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af",
  },
});

console.log(topics);
// axios
//   .get("http://localhost:3000/api/ethscan/logs/getLogs-by-address-and-topics", {
//     params: {
//       chainid: "1",
//       module: "logs",
//       fromBlock: "24533809",
//       topic0: topics[0],
//       topic0_1_opr: "and",
//       topic1: topics[1],
//       address: "0x8b1484d57abbe239bb280661377363b03c89caea",
//       page: 1,
//       offset: 20,
//     },
//   })
//   .then((r) => {
//     console.log(1);
//     console.log(r);
//   });
