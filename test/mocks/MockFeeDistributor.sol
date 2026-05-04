// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeeDistributor} from "../../src/interfaces/IFeeDistributor.sol";

/// @dev Simple fee distributor: caller pushes fees in, claim() pulls them out.
///      Tests call `addFees()` to simulate protocol fee accrual between blocks.
contract MockFeeDistributor is IFeeDistributor {
    using SafeERC20 for IERC20;

    address public override token;
    mapping(address => uint256) private _claimable;

    constructor(address _token) {
        token = _token;
    }

    /// @dev Test helper — simulates the protocol dropping fees into the distributor.
    function addFees(address recipient, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _claimable[recipient] += amount;
    }

    function claim(address addr) external override returns (uint256 amount) {
        amount = _claimable[addr];
        if (amount > 0) {
            _claimable[addr] = 0;
            IERC20(token).safeTransfer(addr, amount);
        }
    }

    function claimable(address addr) external view override returns (uint256) {
        return _claimable[addr];
    }
}
