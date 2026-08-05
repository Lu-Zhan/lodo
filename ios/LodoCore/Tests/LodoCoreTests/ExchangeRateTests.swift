import XCTest
@testable import LodoCore

/// 汇率纯逻辑测试:换算公式、payload 解析(不发网络请求,网络层在 ExchangeRateClient.fetchRates)。
final class ExchangeRateTests: XCTestCase {

    // MARK: - ExchangeRateTable.convert

    func testConvertBetweenTwoNonBaseCurrencies() {
        let table = ExchangeRateTable(
            base: "USD", rates: ["CNY": 7.0, "EUR": 0.9], fetchedAt: Date())
        // 100 CNY -> USD -> EUR: 100 / 7.0 * 0.9
        let result = table.convert(100, from: "CNY", to: "EUR")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 100.0 / 7.0 * 0.9, accuracy: 0.0001)
    }

    func testConvertFromBaseCurrency() {
        let table = ExchangeRateTable(base: "USD", rates: ["CNY": 7.0], fetchedAt: Date())
        XCTAssertEqual(table.convert(10, from: "USD", to: "CNY")!, 70, accuracy: 0.0001)
    }

    func testConvertSameCurrencyIsIdentity() {
        let table = ExchangeRateTable(base: "USD", rates: ["CNY": 7.0], fetchedAt: Date())
        XCTAssertEqual(table.convert(50, from: "CNY", to: "CNY")!, 50, accuracy: 0.0001)
    }

    func testConvertUnknownCurrencyReturnsNil() {
        let table = ExchangeRateTable(base: "USD", rates: ["CNY": 7.0], fetchedAt: Date())
        XCTAssertNil(table.convert(10, from: "CNY", to: "JPY"))
        XCTAssertNil(table.convert(10, from: "JPY", to: "CNY"))
    }

    // MARK: - ExchangeRateClient.parseRatesPayload

    func testParseRatesPayload() throws {
        let table = try ExchangeRateClient.parseRatesPayload(
            ["amount": 1.0, "base": "USD", "rates": ["CNY": 7.15, "EUR": 0.87]],
            base: "USD", fetchedAt: Date())
        XCTAssertEqual(table.base, "USD")
        XCTAssertEqual(table.rates["CNY"], 7.15)
        XCTAssertEqual(table.rates["EUR"], 0.87)
        // base 自身补 1.0
        XCTAssertEqual(table.rates["USD"], 1.0)
    }

    func testParseRatesPayloadMissingRatesThrows() {
        XCTAssertThrowsError(
            try ExchangeRateClient.parseRatesPayload(["base": "USD"], base: "USD", fetchedAt: Date()))
    }

    func testParseRatesPayloadEmptyRatesThrows() {
        XCTAssertThrowsError(try ExchangeRateClient.parseRatesPayload(
            ["rates": [String: Any]()], base: "USD", fetchedAt: Date()))
    }
}
