//
//  MPVCommandWrappers.swift
//  iina
//
//  Created by Yuze Jiang on 2025/05/25.
//  Copyright © 2025 lhc. All rights reserved.
//

extension MPVController {
  enum DiscNavigationAction: String {
    case up, down, left, right, select, popup, resume
    case topMenu = "top-menu"
    case mouseMove = "mouse-move"
    case mouseClick = "mouse-click"
  }

  static let discMenuActiveProperty = "disc-menu-active"
  static let discMenuPopupAvailableProperty = "disc-menu-popup-available"
  static let discMouseOnButtonProperty = "disc-mouse-on-button"

  func discNavigate(_ action: DiscNavigationAction) {
    command(MPVCommand("discnav"), args: [action.rawValue], checkError: false, level: .verbose)
  }

  func playlistInsert(_ path: String, index: Int) {
    command(.loadfile, args: [path, "insert-at", index.description], level: .verbose)
  }

  func playlistAppend(_ path: String) {
    command(.loadfile, args: [path, "append"], level: .verbose)
  }

  func playlistMove(_ from: Int, to: Int) {
    command(.playlistMove, args: ["\(from)", "\(to)"], level: .verbose)
  }

  func playlistRemove(_ index: Int) {
    command(.playlistRemove, args: [index.description], level: .verbose)
  }

}
