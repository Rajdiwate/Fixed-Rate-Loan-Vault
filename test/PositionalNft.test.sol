// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {PositionNFT} from "../src/contracts/positionalNft/PositionNFT.sol";

contract PositionNFTTest is Test {
  PositionNFT internal positionNFT;

  address internal owner = address(this);
  address internal controller = address(0xC0FFEE);
  address internal newController = address(0xC0FFEE2);
  address internal institution1 = address(0xA11CE);
  address internal institution2 = address(0xB0B);

  function setUp() public {
    owner; // explicit for readability
    positionNFT = new PositionNFT("Institution Position", "iPOS", controller);
  }

  function testConstructorSetsVaultController() public view {
    assertEq(positionNFT.vaultController(), controller);
  }

  function testMintRevertsForNonController() public {
    vm.prank(institution1);
    vm.expectRevert(bytes("Not authorized"));
    positionNFT.mint(institution1);
  }

  function testMintByControllerAssignsOwnerAndIncrementsTokenId() public {
    vm.prank(controller);
    uint256 tokenId1 = positionNFT.mint(institution1);
    assertEq(tokenId1, 1);
    assertEq(positionNFT.ownerOf(tokenId1), institution1);

    vm.prank(controller);
    uint256 tokenId2 = positionNFT.mint(institution2);
    assertEq(tokenId2, 2);
    assertEq(positionNFT.ownerOf(tokenId2), institution2);
  }

  function testSetVaultControllerOnlyOwner() public {
    vm.prank(institution1);
    vm.expectRevert();
    positionNFT.setVaultController(newController);

    positionNFT.setVaultController(newController);
    assertEq(positionNFT.vaultController(), newController);
  }

  function testTransferRevertsForTokenOwnerWhenNotContractOwner() public {
    vm.prank(controller);
    uint256 tokenId = positionNFT.mint(institution1);

    vm.prank(institution1);
    vm.expectRevert(bytes("PositionNFT: transfers restricted to owner"));
    positionNFT.transferFrom(institution1, institution2, tokenId);
  }

  function testTransferAllowedForContractOwner() public {
    vm.prank(controller);
    uint256 tokenId = positionNFT.mint(institution1);

    // ERC721 auth still applies: token owner approves contract owner.
    vm.prank(institution1);
    positionNFT.approve(owner, tokenId);

    // Contract owner is address(this), allowed by _update override.
    positionNFT.transferFrom(institution1, institution2, tokenId);
    assertEq(positionNFT.ownerOf(tokenId), institution2);
  }
}
