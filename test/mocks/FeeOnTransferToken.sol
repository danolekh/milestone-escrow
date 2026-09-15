// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC-20 that burns a fixed percentage on every transfer. Used to prove `fund` rejects
///      tokens that deliver less than requested.
contract FeeOnTransferToken is ERC20 {
    uint256 public immutable FEE_BPS;

    constructor(uint256 feeBps) ERC20("Fee Token", "FEE") {
        FEE_BPS = feeBps;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = (value * FEE_BPS) / 10_000;
            if (fee != 0) {
                super._update(from, address(0), fee);
                value -= fee;
            }
        }
        super._update(from, to, value);
    }
}
