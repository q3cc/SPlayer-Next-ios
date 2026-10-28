import XCTest

@testable import SPlayerNativeUI

/// 登录后账号信息的数据契约：字段与共享服务 account 动作返回值一致
final class NativeAccountTests: XCTestCase {
  func testAccountDecodesServicePayload() throws {
    let json = """
      {"userId":7,"nickname":"听众","avatarUrl":"https://a.cn/1","signature":"签名","vipType":11,
       "playlistCount":3,"albumCount":1,"artistCount":5,
       "liked":{"id":"1","title":"我喜欢的音乐","cover":"c","subtitle":"10 首","kind":"playlist"},
       "created":[{"id":"2","title":"自建","cover":"c","kind":"playlist"}],
       "subscribed":[],
       "albums":[{"id":"9","title":"专辑","cover":"c","subtitle":"歌手","kind":"album"}],
       "artists":[{"id":"8","title":"歌手","cover":"a","kind":"artist"}]}
      """
    let account = try JSONDecoder().decode(NativeAccount.self, from: Data(json.utf8))
    XCTAssertTrue(account.isVip)
    XCTAssertNil(account.level)
    XCTAssertEqual(account.liked?.subtitle, "10 首")
    XCTAssertEqual(account.albums.first?.kind, "album")
    XCTAssertNil(account.created.first?.subtitle)
  }

  func testOldBookmarksWithoutKindStillDecode() throws {
    let json = #"[{"id":"1","title":"歌单","cover":"c","subtitle":null}]"#
    let covers = try JSONDecoder().decode([NativeCover].self, from: Data(json.utf8))
    XCTAssertNil(covers.first?.kind)
  }
}
