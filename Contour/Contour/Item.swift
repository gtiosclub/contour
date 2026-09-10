//
//  Item.swift
//  Contour
//
//  Created by Neel Maddu on 9/10/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
