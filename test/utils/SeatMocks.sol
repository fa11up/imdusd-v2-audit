// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract MockSeatNFT is ERC721 {
    constructor() ERC721("identity.md", "IDMD") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

/// @notice The live Adapter8004's shape: register(uint8,address,uint256,string), gated on ownerOf == caller.
contract MockAgentAdapter {
    uint256 public next = 100;

    error NotOwner();

    function register(uint8, address collection, uint256 tokenId, string calldata) external returns (uint256) {
        if (IERC721(collection).ownerOf(tokenId) != msg.sender) revert NotOwner();
        return next++;
    }
}

/// @notice Pays `amount` of `token` to `account`, as the plane's MerkleDistributor pays a leaf.
contract MockDistributor {
    function claim(address account, address token, uint256 amount) external {
        IERC20(token).transfer(account, amount);
    }

    function other(address account, address token, uint256 amount) external {
        IERC20(token).transfer(account, amount);
    }
}

contract MockDistributorFactory {
    mapping(uint64 => address) public distributorOf;

    function set(uint64 launch, address d) external {
        distributorOf[launch] = d;
    }
}

/// @notice A reward token that refuses every transfer out of `blocked`.
/// @dev A token whose transfer costs what a first-time recipient plus a little logic can cost at Glamsterdam's prices.
contract MockHungryToken {
    mapping(address => uint256) public balanceOf;
    uint256 public burn;

    constructor(uint256 burn_) {
        burn = burn_;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        uint256 stop = gasleft() - burn;
        while (gasleft() > stop) {}
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract MockStuckToken {
    mapping(address => uint256) public balanceOf;
    address public blocked;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function block_(address who) external {
        blocked = who;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        require(msg.sender != blocked, "stuck");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}
