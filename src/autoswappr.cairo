#[starknet::contract]
// @title AutoSwappr Contract
// @dev Implements upgradeable pattern and ownership control
pub mod AutoSwappr {
    use pragma_lib::abi::{IPragmaABIDispatcher, IPragmaABIDispatcherTrait};
    use pragma_lib::types::{AggregationMode, DataType, PragmaPricesResponse};
    use crate::interfaces::iautoswappr::{IAutoSwappr, ContractInfo};
    use crate::base::types::{Route, Assets, RouteParams, SwapParams};
    use openzeppelin_upgrades::UpgradeableComponent;
    use openzeppelin_upgrades::interface::IUpgradeable;
    use starknet::storage::{
        Map, StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry
    };
    use crate::base::errors::Errors;

    use core::starknet::{
        ContractAddress, get_caller_address, contract_address_const, get_contract_address, ClassHash
    };

    use openzeppelin::access::ownable::OwnableComponent;
    use crate::interfaces::iavnu_exchange::{IExchangeDispatcher, IExchangeDispatcherTrait};
    use crate::interfaces::ifibrous_exchange::{
        IFibrousExchangeDispatcher, IFibrousExchangeDispatcherTrait
    };
    use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};

    use core::integer::{u256, u128};
    use core::num::traits::Zero;
    use alexandria_math::fast_power::fast_power;

    const ETH_KEY: felt252 = 'ETH/USD';
    const STRK_KEY: felt252 = 'STRK/USD';

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;

    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    // @notice Storage struct containing all contract state variables
    // @dev Includes mappings for supported assets and critical contract addresses
    #[storage]
    struct Storage {
        // strk_token: ContractAddress,
        // eth_token: ContractAddress,
        fees_collector: ContractAddress,
        fee_amount_bps: u8, // 50 = 0.5$ fee
        avnu_exchange_address: ContractAddress,
        fibrous_exchange_address: ContractAddress,
        oracle_address: ContractAddress,
        supported_assets_to_feed_id: Map<ContractAddress, felt252>,
        autoswappr_addresses: Map<ContractAddress, bool>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
    }

    // @notice Events emitted by the contract

    #[event]
    #[derive(starknet::Event, Drop)]
    pub enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        SwapSuccessful: SwapSuccessful,
        Subscribed: Subscribed,
        Unsubscribed: Unsubscribed
    }

    #[derive(Drop, starknet::Event)]
    // @notice Event emitted when a swap is successfully executed
    // @param token_from_address Address of the token being sold
    // @param token_from_amount Amount of tokens being sold
    // @param token_to_address Address of the token being bought
    // @param token_to_amount Amount of tokens being bought
    // @param beneficiary Address receiving the bought tokens
    pub struct SwapSuccessful {
        pub token_from_address: ContractAddress,
        pub token_from_amount: u256,
        pub token_to_address: ContractAddress,
        pub token_to_amount: u256,
        pub beneficiary: ContractAddress
    }

    #[derive(starknet::Event, Drop)]
    pub struct Subscribed {
        pub user: ContractAddress,
        pub assets: Assets,
    }

    #[derive(starknet::Event, Drop)]
    pub struct Unsubscribed {
        pub user: ContractAddress,
        pub assets: Assets,
        pub block_timestamp: u64
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        fees_collector: ContractAddress,
        fee_amount_bps: u8,
        avnu_exchange_address: ContractAddress,
        fibrous_exchange_address: ContractAddress,
        oracle_address: ContractAddress,
        // _strk_token: ContractAddress,
        // _eth_token: ContractAddress,
        supported_assets: Array<ContractAddress>,
        supported_assets_priceFeeds_ids: Array<felt252>,
        owner: ContractAddress,
    ) {
        assert(
            !supported_assets.is_empty()
                && supported_assets.len() == supported_assets_priceFeeds_ids.len(),
            Errors::INVALID_INPUT
        );

        for i in 0
            ..supported_assets
                .len() {
                    self
                        .supported_assets_to_feed_id
                        .write(*supported_assets[i], *supported_assets_priceFeeds_ids[i]);
                };
        self.fees_collector.write(fees_collector);
        self.fee_amount_bps.write(fee_amount_bps);
        // self.strk_token.write(_strk_token);
        // self.eth_token.write(_eth_token);
        self.fibrous_exchange_address.write(fibrous_exchange_address);
        self.avnu_exchange_address.write(avnu_exchange_address);
        self.oracle_address.write(oracle_address);
        self.ownable.initializer(owner);
        // self.supported_assets.entry(_strk_token).write(true);
    // self.supported_assets.entry(_eth_token).write(true);
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.ownable.assert_only_owner();
            self.upgradeable.upgrade(new_class_hash);
        }
    }


    #[abi(embed_v0)]
    impl AutoSwappr of IAutoSwappr<ContractState> {
        fn avnu_swap(
            ref self: ContractState,
            token_from_address: ContractAddress,
            token_from_amount: u256,
            token_to_address: ContractAddress,
            token_to_amount: u256,
            token_to_min_amount: u256,
            beneficiary: ContractAddress,
            integrator_fee_amount_bps: u128,
            integrator_fee_recipient: ContractAddress,
            routes: Array<Route>,
        ) {
            assert(
                self.autoswappr_addresses.entry(get_caller_address()).read() == true,
                Errors::INVALID_SENDER
            );

            assert(!token_from_amount.is_zero(), Errors::ZERO_AMOUNT);
            assert(
                self.check_if_token_from_is_supported(token_from_address), Errors::UNSUPPORTED_TOKEN
            );

            let this_contract = get_contract_address();
            let token_from_contract = ERC20ABIDispatcher { contract_address: token_from_address };
            let token_to_contract = ERC20ABIDispatcher { contract_address: token_to_address };

            assert(
                token_from_contract
                    .allowance(get_caller_address(), this_contract) >= token_from_amount,
                Errors::INSUFFICIENT_ALLOWANCE,
            );

            token_from_contract
                .transfer_from(get_caller_address(), this_contract, token_from_amount);
            token_from_contract.approve(self.avnu_exchange_address.read(), token_from_amount);
            let contract_token_to_balance = token_to_contract.balance_of(this_contract);

            let swap = self
                ._avnu_swap(
                    token_from_address,
                    token_from_amount,
                    token_to_address,
                    token_to_amount,
                    token_to_min_amount,
                    // beneficiary,
                    this_contract, // only caller address can be the beneficiary, in this case, the contract. 
                    integrator_fee_amount_bps,
                    integrator_fee_recipient,
                    routes
                );
            assert(swap, Errors::SWAP_FAILED);

            let new_contract_token_to_balance = token_to_contract.balance_of(this_contract);
            let token_to_received = new_contract_token_to_balance - contract_token_to_balance;
            let updated_token_to_received = self
                ._collect_fees(token_to_received, token_to_contract);
            token_to_contract.transfer(beneficiary, updated_token_to_received);

            self
                .emit(
                    SwapSuccessful {
                        token_from_address,
                        token_from_amount,
                        token_to_address,
                        token_to_amount: token_to_received,
                        beneficiary
                    }
                );
        }

        fn fibrous_swap(
            ref self: ContractState,
            routeParams: RouteParams,
            swapParams: Array<SwapParams>,
            beneficiary: ContractAddress
        ) {
            let caller_address = get_caller_address();
            let contract_address = get_contract_address();

            // assertions
            assert(self.autoswappr_addresses.entry(caller_address).read(), Errors::INVALID_SENDER,);
            assert(
                self.check_if_token_from_is_supported(routeParams.token_in),
                Errors::UNSUPPORTED_TOKEN,
            );
            assert(!routeParams.amount_in.is_zero(), Errors::ZERO_AMOUNT);

            let token_in_contract = ERC20ABIDispatcher { contract_address: routeParams.token_in };
            let token_out_contract = ERC20ABIDispatcher { contract_address: routeParams.token_out };
            assert(
                token_in_contract
                    .allowance(caller_address, contract_address) >= routeParams
                    .amount_in,
                Errors::INSUFFICIENT_ALLOWANCE,
            );

            // Approve commission taking from fibrous
            token_in_contract
                .transfer_from(caller_address, contract_address, routeParams.amount_in);
            token_in_contract.approve(self.fibrous_exchange_address.read(), routeParams.amount_in);
            let contract_token_out_balance = token_out_contract.balance_of(contract_address);
            self._fibrous_swap(routeParams.clone(), swapParams,);

            let new_contract_token_out_balance = token_out_contract.balance_of(contract_address);
            let token_out_received = new_contract_token_out_balance - contract_token_out_balance;
            let updated_token_out_received = self
                ._collect_fees(token_out_received, token_out_contract);
            token_out_contract.transfer(beneficiary, updated_token_out_received);

            self
                .emit(
                    SwapSuccessful {
                        token_from_address: routeParams.token_in,
                        token_from_amount: routeParams.amount_in,
                        token_to_address: routeParams.token_out,
                        token_to_amount: token_out_received,
                        beneficiary
                    }
                );
        }

        // fn get_strk_usd_price(self: @ContractState) -> (u128, u32) {
        //     // let (price, decimals) =
        //     self.get_asset_price_median(DataType::SpotEntry(STRK_KEY));
        //     // price / (fast_power(10_u32, decimals)).into()
        //     // This above code will return 0 because u128 cannot hold decimals and
        //     // the current strk price is around 0.4
        //     self.get_asset_price_median(DataType::SpotEntry(STRK_KEY))
        // }

        // fn get_eth_usd_price(self: @ContractState) -> u128 {
        //     let (price, decimals) = self.get_asset_price_median(DataType::SpotEntry(ETH_KEY));
        //     price / (fast_power(10_u32, decimals)).into()
        // }

        fn get_token_price_in_usd(
            self: @ContractState, token: ContractAddress, token_amount: u256
        ) -> u256 {
            let feed_id = self.supported_assets_to_feed_id.read(token);
            let (price, decimals) = self.get_asset_price_median(DataType::SpotEntry(feed_id));
            price.into() * token_amount / fast_power(10_u32, decimals).into()
        }

        fn set_operator(ref self: ContractState, address: ContractAddress) {
            assert(get_caller_address() == self.ownable.owner(), Errors::NOT_OWNER);
            assert(
                self.autoswappr_addresses.entry(address).read() == false, Errors::EXISTING_ADDRESS
            );
            self.autoswappr_addresses.entry(address).write(true);
        }

        fn remove_operator(ref self: ContractState, address: ContractAddress) {
            assert(get_caller_address() == self.ownable.owner(), Errors::NOT_OWNER);
            assert(
                self.autoswappr_addresses.entry(address).read() == true,
                Errors::NON_EXISTING_ADDRESS
            );
            self.autoswappr_addresses.entry(address).write(false);
        }

         fn is_operator(self: @ContractState, address: ContractAddress) -> bool {
            self.autoswappr_addresses.read(address)
        }

        fn check_if_token_from_is_supported(
            self: @ContractState, token_from: ContractAddress
        ) -> bool {
            !(self.supported_assets_to_feed_id.read(token_from) == '')
        }

        fn contract_parameters(self: @ContractState) -> ContractInfo {
            ContractInfo {
                fees_collector: self.fees_collector.read(),
                fibrous_exchange_address: self.fibrous_exchange_address.read(),
                avnu_exchange_address: self.avnu_exchange_address.read(),
                oracle_address: self.oracle_address.read(),
                owner: self.ownable.owner()
            }
        }

        // @notice Checks if an account is an operator
        // @param address Account address to check
        // @return bool true if the account is an operator, false otherwise
       
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {

        fn _avnu_swap(
            ref self: ContractState,
            token_from_address: ContractAddress,
            token_from_amount: u256,
            token_to_address: ContractAddress,
            token_to_amount: u256,
            token_to_min_amount: u256,
            beneficiary: ContractAddress,
            integrator_fee_amount_bps: u128,
            integrator_fee_recipient: ContractAddress,
            routes: Array<Route>,
        ) -> bool {
            let avnu = IExchangeDispatcher { contract_address: self.avnu_exchange_address.read() };

            avnu
                .multi_route_swap(
                    token_from_address,
                    token_from_amount,
                    token_to_address,
                    token_to_amount,
                    token_to_min_amount,
                    beneficiary,
                    integrator_fee_amount_bps,
                    integrator_fee_recipient,
                    routes
                )
        }

        fn _fibrous_swap(
            ref self: ContractState, routeParams: RouteParams, swapParams: Array<SwapParams>,
        ) {
            let fibrous = IFibrousExchangeDispatcher {
                contract_address: self.fibrous_exchange_address.read()
            };

            fibrous.swap(routeParams, swapParams);
        }

        fn get_asset_price_median(self: @ContractState, asset: DataType) -> (u128, u32) {
            let oracle_dispatcher = IPragmaABIDispatcher {
                contract_address: self.oracle_address.read()
            };
            let output: PragmaPricesResponse = oracle_dispatcher
                .get_data(asset, AggregationMode::Median(()));
            return (output.price, output.decimals);
        }

        fn _collect_fees(
            ref self: ContractState, token_to_received: u256, token_to_contract: ERC20ABIDispatcher
        ) -> u256 {
            let token_to_decimals = token_to_contract.decimals();
            assert(token_to_decimals > 0, Errors::INVALID_DECIMALS);
            let fee: u256 = (self.fee_amount_bps.read()
                * fast_power(10_u8, token_to_decimals)
                / 100)
                .into();
            token_to_contract.transfer(self.fees_collector.read(), fee);
            token_to_received - fee
        }

        // @notice Returns the zero address constant
        fn zero_address(self: @ContractState) -> ContractAddress {
            contract_address_const::<0>()
        }
    }

    fn is_non_zero(address: ContractAddress) -> bool {
        address.into() != 0
    }
}
