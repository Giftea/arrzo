// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITroveManager, IPriceFeed} from "../../src/interfaces/ITroveManager.sol";

contract MockTroveManager is ITroveManager {
    uint256 private _tcr;

    constructor(uint256 initialTCR) {
        _tcr = initialTCR;
    }

    function setTCR(uint256 tcr) external {
        _tcr = tcr;
    }

    function getTCR(uint256 /*_price*/ ) external view override returns (uint256) {
        return _tcr;
    }

    /// Recovery Mode when TCR < 150 % (CCR).
    function checkRecoveryMode(uint256 /*_price*/ ) external view override returns (bool) {
        return _tcr < 1.5e18;
    }
}

contract MockPriceFeed is IPriceFeed {
    uint256 private _price;

    constructor(uint256 initialPrice) {
        _price = initialPrice;
    }

    function setPrice(uint256 price) external {
        _price = price;
    }

    function lastGoodPrice() external view override returns (uint256) {
        return _price;
    }
}
