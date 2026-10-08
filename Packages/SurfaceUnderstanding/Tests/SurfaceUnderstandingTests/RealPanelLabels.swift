import ContourCore

/// Labels main's LabelReader read off the team's Drive photos (Oct 8):
/// 18 microwaves and 2 ovens, plus three of Vrishin's hand-labelled panels.
/// Unlabelled buttons are left out.
enum RealPanelLabels {
    static let lists: [String: [String]] = [
        "Angle.jpeg": ["30g", "•Express", "Popcorm", "Beverage", "Vegetable", "Potato", "Chicken", "Cook Time", "Leve Powe", "Time", "0000017272", "Defrost", "Cook"],
        "Glare.jpeg": ["3:00", "Popcorn", "Defrost time/weight", "Potato", "egetable", "Power Level", "Timer on/off", "Chicken", "cance", "GA TECH HOUSING", "0000017272", "ok", "Express Cook", "1", "6", "5", "4", "9", "7", "display on/off"],
        "MicrowaveGlare.heif": ["0:00", "Entree Frozen", "Detfost Weight", "plate Dinner", "Popcom", "Reheat pizza", "Time Cook", "Porato", "SOup", "Beverage Vegerable Vegetabie Defrost Frozen Timed", "6", "1"],
        "MicrowaveStraight.HEIC": ["0:0 0", "Frozen Entree", "Timed Defrost", "Plate Dinner", "Level Power", "Favorite", "Potato", "Soup", "Reheat Pizza", "Papcorn", "Beverage Vegetable Frozen", "Diefrost Vegetable Weight Fresh", "6", "5"],
        "Neat1.jpeg": ["Popcorn", "Beverage", "PM AM or", "Start Pause", "Vegetable", "Defrost time/weight", "Time Cook", "Potato", "Chicken", "Power Level", "Timer on/off", "Fish", "Reheat", "30 Add Sec", "Clock", "GA TECH HOUSING", "0000017272", "3:00", "Cook", "Time", "Express Cook", "2", "1", "5", "6", "4", "7", "8", "9", "display on/off", "Cancel Off"],
        "Neat2.jpeg": ["Popcorn", "Beverage", "Vegetable", "Time Cook", "Defrost time/weight", "Potato", "Chicken", "Power Level", "Timer on/off", "Reheat", "Fish", "30 Add Sec", "Clock", "or AM PM", "7", "GA TECH HOUSING", "0000017272", "13:0", "Time", "Cook", "Express Cook", "6", "9", "8", "display on/off", "Cancel", "Start Pause", "Off"],
        "OvenStraight.heif": ["Timer Set/Off", "10:43", "Ligr", "Broil", "Temp/Time", "Keep Warm", "Cook Time", "Delay Start", "Control LOCk Hold 3 sec", "Clock"],
        "angle-microwave.heif": ["0:0 1", "Defrost Weight", "Plate Dinner", "Popcorn", "Level Power", "Beverage", "2", "Reheat Pizza", "Soup", "Entree Frozen", "Vegetable Fresh Defrost Frozen Vegetable Timed Favorite Potato", "COOk Time", "3", "1", "6", "5", "Clock"],
        "angle_microwave.jpg": ["Kitchen Timer", "Time Cook", "Beverage", "10:45 Defrost Add Weight/Time 30 Sec Power Clock Popcorn Potato Pizza Frozen Vegetable Dinner Plate Express Cook", "Start Pause"],
        "glare_microwave.jpg": ["10:47", "2", "5", "7", "8", "Start", "Door", "Unlock", "3", "1", "Time Cook", "Defrost Weight/Time", "Add 30 Sec", "Kitchen Timer", "Power", "Clock", "Potato", "Pizza", "Popcorn", "Dinners Plate", "Frozen Vegetable", "Beverage", "Express Cook", "4", "Cancel Off", "Pause"],
        "microwave1_angle.heif": ["12:0 1", "CANCEL", "Power Cook", "Popcorn", "Cook Time", "Pizza", "Potato", "Melt Soften/", "Reheat", "Cook", "Defrost", "2", "1", "4", "5", "8", "9", "Timer Set/Off", "Clock", "D", "30 Sec", "START"],
        "microwave1_glare.heif": ["12:05", "START", "CANCEL", "+ 30", "Cook Power", "Meit Soften/", "Cook Time", "Potato", "Timer SeYOT", "Cook", "5", "Popcorn", "Pizza", "Reneat", "Defrost", "3", "1", "6", "9", "8", "7", "Clock", "Sec"],
        "microwave1_neat.heif": ["12:03", "CANCEL", "START", "Soften/ Melt", "Timer Set/Off", "Cook Power", "Time Cook", "+ 30 Sec", "9", "Pizza", "Potato", "Popcorn", "Reheat", "Cook", "Defrost", "2", "1", "6", "5", "8", "Clock", "Hold 3 sec", "Please It do will not damage cook Please the food use directly ceramic/glass cookware. on t", "Thanks, Department of Housing"],
        "microwave1_neat2.heif": ["CANCEL", "Soften/ Melt", "Cook Power", "Cook Time", "Popcorn", "Defrost", "30 Sec", "Reheat", "Potato", "Pizza", "8", "6", "5", "1", "Cook", "2", "4", "7", "Timer Set/Off", "Clock", "Hold 3 sec", "ease It", "START", "anks pparti"],
        "microwave2-glare.jpg": ["ại Dinner Plate", "Popcorn", "Baked Potato", "Frozen", "Vegetable", "Beverage", "Pizza", "Time Defrost", "Weight Defrost", "Express Cook", "2", "7", "Clock", "Tirne", "Power", "COOR", "START", "STOP"],
        "microwave2-neat.jpg": ["6", "1:3~", "Oz", "Plate Dinner", "Pepcorn Vegetable Frozen", "Baked Potato", "Pizza", "Beverage", "Weight Defrost", "Time Defrost", "Express Cook", "2", "5", "9", "7", "8", "Memory", "STOP CANCEL"],
        "microwave2-neat2.jpg": ["Weight Defrost", "Baked Potato", "Time Defrost", "Time Cook", "1:35", "Oz", "Plate Dinner", "Popcorn", "Vegetable Frozen", "Beverage", "Pizza", "Express Cook", "2", "6", "5", "7", "8", "9", "Clock", "Timer", "Memory", "START →vûsec."],
        "neat-microwave.heif": ["Vegetable Fresh veretable", "Control Lock", "- 30 sec", "roze atre", "Weight Defrost", "Plate Dinner", "Level Power", "Timed Defrost", "Cine", "Potato", "Soup", "Popcorn", "Reheat Pizza", "Beverage", "Favorite", "2", "З", "1", "4", "5", "6", "7", "9", "Timer", "Clock"],
        "neat-oven.heif": ["10:38", "Keep Warm", "Start Cancel", "Broil", "ayeg", "3 hold sec", "LO", "Self Clean Steam Clean", "Temp/Time", "Clock Set/Off Timer Light Oven", "Cook Time", "Time Start", "Whirpool"],
        "normal_microwave.jpg": ["Clock", "Frozen Vegetable", "Popcorn", "Power", "Potato", "Pizza", "2", "6", "5", "7", "9", "30 Sec", "8", "Start Pause", "Cook", "Door", "I0•70", "Time", "Add", "Defrost", "Weight/Time", "Kitchen Timer", "Dinner Plate", "Beverage", "Express Cook", "1", "4", "Cancel Off", "Unlock"],
        "hand-labelled microwave-01.jpg": ["Time Cook", "Defrost Weight/Time", "Add 30 Sec", "Power", "Clock", "Kitchen Timer", "Popcorn", "Potato", "Pizza", "Frozen Vegetable", "Beverage", "Dinner Plate", "1", "2", "3", "4", "5", "6", "7", "8", "9", "Cancel/Off", "0", "Start/Pause"],
        "hand-labelled microwave-04.jpg": ["Popcorn", "Dinner Plate", "Frozen Vegetable", "Baked Potato", "Pizza", "Beverage", "Weight Defrost", "Time Defrost", "1", "2", "3", "4", "5", "6", "7", "8", "9", "Clock", "0", "Timer", "Power", "Time Cook", "Stop/Cancel", "Start/+30 Sec"],
        "hand-labelled microwave-08.jpg": ["Popcorn", "Time Cook", "Defrost Time/Weight", "Beverage", "Power Level", "Timer", "Vegetable", "Potato", "Chicken", "Fish", "Reheat", "Add 30 Sec", "1", "2", "3", "4", "5", "6", "7", "8", "9", "Clock", "0", "AM/PM", "Start/Pause", "Cancel/Off"],
    ]

    /// A map with one button per label, in order. Crashes on a misspelled name,
    /// so a typo can't quietly turn into an empty panel that returns nil.
    static func map(_ name: String) -> SurfaceMap {
        guard let labels = lists[name] else { fatalError("no labels for \(name)") }
        return SurfaceMap(buttons: labels.enumerated().map { i, label in
            SurfaceMap.Button(label: label, bounds: PanelRect(x: 0, y: Double(i) / Double(labels.count), width: 1, height: 0.01), confidence: 1)
        }, confidence: 1)
    }
}