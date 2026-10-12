// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IDecentralizedApp, KeyValue, OnchainDataResource } from "../src/OnchainDataResource.sol";

interface DataResourceVm {
    function deal(address account, uint256 balance) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address caller) external;
}

contract OnchainDataResourceTest {
    DataResourceVm private constant vm =
        DataResourceVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    OnchainDataResource private resource;
    address payable private constant RECIPIENT = payable(address(0xFEE));
    address private constant OTHER = address(0xBAD);
    uint256 private constant WRITE_PRICE = 7 wei;

    function setUp() public {
        resource = new OnchainDataResource(WRITE_PRICE, RECIPIENT);
        vm.deal(address(this), 1 ether);
    }

    function testPaidInlineWriteIsReadableThroughErc5219() public {
        string[] memory path = _path("notes", "foam");
        (bytes32 key, bytes32 digest, uint64 version) =
            resource.publishInline{ value: WRITE_PRICE }(path, "text/plain", "literal foam");
        require(key == resource.resourceKey(path), "resource key drift");
        require(digest == sha256("literal foam"), "sha-256 drift");
        require(version == 1, "initial version drift");

        (uint16 status, string memory body, KeyValue[] memory headers) =
            resource.request(path, new KeyValue[](0));
        require(status == 200, "inline status drift");
        require(keccak256(bytes(body)) == keccak256("literal foam"), "inline body drift");
        require(keccak256(bytes(headers[0].value)) == keccak256("text/plain"), "media drift");
    }

    function testExternalBodyKeepsDigestAndStandardLocatorResponse() public {
        string[] memory path = _path("objects", "large");
        bytes32 digest = sha256("bucket bytes");
        resource.publishExternal{ value: WRITE_PRICE }(
            path, "application/cbor", "https://objects.example/sha256/example", digest
        );

        (uint16 status, string memory body, KeyValue[] memory headers) =
            resource.request(path, new KeyValue[](0));
        require(status == 200, "external status drift");
        require(
            keccak256(bytes(body)) == keccak256("https://objects.example/sha256/example"),
            "external locator drift"
        );
        require(
            keccak256(bytes(headers[0].value))
                == keccak256(
                    "message/external-body; access-type=URL; URL=\"https://objects.example/sha256/example\""
                ),
            "external-body media drift"
        );
        require(keccak256(bytes(headers[2].key)) == keccak256("Content-Location"), "header drift");
    }

    function testWriterMustPayExactPrice() public {
        string[] memory path = _path("notes", "unpaid");
        vm.expectRevert(
            abi.encodeWithSelector(
                OnchainDataResource.IncorrectWritePayment.selector, WRITE_PRICE, 0
            )
        );
        resource.publishInline(path, "text/plain", "no consideration");
    }

    function testAnotherActorCannotOverwriteControlledPath() public {
        string[] memory path = _path("notes", "controlled");
        resource.publishInline{ value: WRITE_PRICE }(path, "text/plain", "v1");
        bytes32 key = resource.resourceKey(path);
        vm.deal(OTHER, WRITE_PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                OnchainDataResource.ResourceControlledByAnotherActor.selector, key, address(this)
            )
        );
        vm.prank(OTHER);
        resource.publishInline{ value: WRITE_PRICE }(path, "text/plain", "hostile overwrite");
    }

    function testDeclaresErc5219Interface() public view {
        require(resource.supportsInterface(type(IDecentralizedApp).interfaceId), "missing ERC-5219");
    }

    function _path(string memory first, string memory second)
        private
        pure
        returns (string[] memory path)
    {
        path = new string[](2);
        path[0] = first;
        path[1] = second;
    }
}
