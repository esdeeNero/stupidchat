import XCTest

final class InterfaceTests: XCTestCase {
    func testChatNavigationSearchAndSettings() {
        let app=XCUIApplication()
        app.launchArguments=["--ui-preview","-AppleLanguages","(ru)","-AppleLocale","ru_RU"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Чаты"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["Алекс"].firstMatch.exists)
        let listShot=XCTAttachment(screenshot:app.screenshot());listShot.name="stupidchat-chats-demo";listShot.lifetime = .keepAlways;add(listShot)
        app.buttons["conversationRow"].firstMatch.tap()
        XCTAssertTrue(app.textFields["messageInput"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Встретимся вечером?"].exists)
        let chatShot=XCTAttachment(screenshot:app.screenshot());chatShot.name="stupidchat-conversation-demo";chatShot.lifetime = .keepAlways;add(chatShot)
        app.buttons["Поиск в переписке"].tap()
        let search=app.textFields["Поиск в переписке"]
        XCTAssertTrue(search.exists);search.tap();search.typeText("логотип")
        XCTAssertTrue(app.staticTexts["Этот хромовый логотип — любовь ✦"].exists)
        XCTAssertFalse(app.staticTexts["Встретимся вечером?"].exists)
        app.navigationBars.buttons.element(boundBy:0).tap()
        app.tabBars.buttons["Настройки"].tap()
        XCTAssertTrue(app.staticTexts["stupidchat"].exists)
        app.buttons["Конфиденциальность"].tap()
        XCTAssertTrue(app.staticTexts["Ограничения прототипа"].exists)
    }
}
