# MilestoneEscrow — developer commands.
#
# Deployment signs with an encrypted Foundry keystore account named `deployer`.
# Create it once (you will be prompted for the key and a password; nothing is written to .env):
#
#     cast wallet import deployer --interactive
#
# RPC URLs and the Etherscan key come from `.env` (see .env.example).

-include .env
export

SCRIPT      := script/Deploy.s.sol:Deploy
CONTRACT    := src/MilestoneEscrow.sol:MilestoneEscrow
VERIFIER_V2 := https://api.etherscan.io/v2/api

.PHONY: help build test test-ci fmt fmt-check coverage gas snapshot clean \
        deploy-sepolia deploy-base verify verify-base slither

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Compile with contract sizes
	forge build --sizes

test: ## Run the full test suite
	forge test -vv

test-ci: ## Run tests with the CI profile (more fuzz/invariant runs)
	FOUNDRY_PROFILE=ci forge test -vvv

fmt: ## Format Solidity
	forge fmt

fmt-check: ## Verify formatting
	forge fmt --check

coverage: ## Coverage summary (excludes test/ and script/)
	forge coverage --report summary --no-match-coverage "(test|script)"

gas: ## Gas report
	forge test --gas-report

snapshot: ## Write .gas-snapshot
	forge snapshot

clean: ## Remove build artifacts
	forge clean

slither: ## Static analysis (requires `pip install slither-analyzer`)
	slither . --config-file slither.config.json

deploy-sepolia: ## Deploy + verify on Base Sepolia (keystore account `deployer`)
	forge script $(SCRIPT) --rpc-url base_sepolia --account deployer --broadcast --verify -vvvv

deploy-base: ## Deploy + verify on Base mainnet (keystore account `deployer`)
	forge script $(SCRIPT) --rpc-url base --account deployer --broadcast --verify -vvvv

# Usage: make verify ADDRESS=0x...
verify: ## Verify an already-deployed contract on Base Sepolia via Etherscan v2
	@test -n "$(ADDRESS)" || (echo "ADDRESS=0x... is required" && exit 1)
	forge verify-contract $(ADDRESS) $(CONTRACT) \
		--verifier etherscan \
		--verifier-url "$(VERIFIER_V2)?chainid=84532" \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--watch

# Usage: make verify-base ADDRESS=0x...
verify-base: ## Verify an already-deployed contract on Base mainnet via Etherscan v2
	@test -n "$(ADDRESS)" || (echo "ADDRESS=0x... is required" && exit 1)
	forge verify-contract $(ADDRESS) $(CONTRACT) \
		--verifier etherscan \
		--verifier-url "$(VERIFIER_V2)?chainid=8453" \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		--watch
