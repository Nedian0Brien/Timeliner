import Foundation
import SwiftData

enum SeedData {
    @MainActor
    static func populateIfNeeded(context: ModelContext) {
        #if DEBUG
        cleanupOldDesignSamples(context: context)

        // Each batch checks its own sentinel, so a store seeded by an earlier
        // build still picks up batches added later.
        var inserted = false
        inserted = seedBaseSamplesIfNeeded(context: context) || inserted
        inserted = seedUpcomingSchedulesIfNeeded(context: context) || inserted
        inserted = seedArchiveIfNeeded(context: context) || inserted

        guard inserted else { return }

        do {
            try context.save()
        } catch {
            context.rollback()
        }
        #endif
    }

    #if DEBUG
    @MainActor
    private static func seedBaseSamplesIfNeeded(context: ModelContext) -> Bool {
        let sentinel = "엄마가 보내준"
        let descriptor = FetchDescriptor<Record>(
            predicate: #Predicate { record in
                record.text.contains(sentinel)
            }
        )

        guard (try? context.fetchCount(descriptor)) == 0 else { return false }

        for schedule in sampleSchedules {
            context.insert(schedule)
        }
        for todo in sampleTodos {
            context.insert(todo)
        }
        for record in sampleRecords {
            context.insert(record)
        }
        return true
    }

    /// Seeded relative to the current date, so the upcoming section always has
    /// content no matter when the store was first populated.
    @MainActor
    private static func seedUpcomingSchedulesIfNeeded(context: ModelContext) -> Bool {
        let sentinel = upcomingSentinel
        let descriptor = FetchDescriptor<Schedule>(
            predicate: #Predicate { schedule in
                schedule.text == sentinel
            }
        )

        guard (try? context.fetchCount(descriptor)) == 0 else { return false }

        for schedule in upcomingSchedules {
            context.insert(schedule)
        }
        for todo in upcomingTodos {
            context.insert(todo)
        }
        return true
    }

    /// Entries stretching back past the two-week window the timeline opens with, so the
    /// pull that widens it has something to find.
    @MainActor
    private static func seedArchiveIfNeeded(context: ModelContext) -> Bool {
        let sentinel = archiveSentinel
        let descriptor = FetchDescriptor<Record>(
            predicate: #Predicate { record in
                record.text == sentinel
            }
        )

        guard (try? context.fetchCount(descriptor)) == 0 else { return false }

        for record in archiveRecords {
            context.insert(record)
        }
        for schedule in archiveSchedules {
            context.insert(schedule)
        }
        return true
    }

    private static let archiveSentinel = "창문을 열어두고 잤더니 새벽에 빗소리에 깼다. 다시 잠들기까지 한참 걸렸지만 싫지 않았다."

    private static var archiveRecords: [Record] {
        let entries: [(Int, Int, Int, String)] = [
            (-8, 20, 10, "퇴근길에 서점에 들렀다. 사려던 책은 없었고 엉뚱한 시집을 한 권 샀다."),
            (-11, 13, 25, "점심에 동료들이랑 새로 생긴 국숫집에 갔다. 줄이 길어서 다음엔 조금 일찍 가기로."),
            (-15, 9, 40, "아침에 자전거 체인에 기름을 쳤다. 소리가 사라지니까 페달이 가벼워진 기분."),
            (-18, 22, 5, archiveSentinel),
            (-23, 16, 50, "오후 내내 사진 정리를 했다. 작년 여름 폴더에서 잊고 있던 사진이 잔뜩 나왔다."),
            (-29, 11, 15, "미뤄둔 우편물을 한꺼번에 뜯었다. 대부분 광고였고 하나는 회신이 필요한 것이었다."),
            (-36, 19, 30, "저녁에 오래된 플레이리스트를 다시 들었다. 그때 뭘 좋아했는지가 고스란히 남아 있었다."),
            (-44, 8, 20, "환절기라 그런지 목이 칼칼해서 따뜻한 물을 계속 마셨다.")
        ]

        return entries.map { offset, hour, minute, text in
            let moment = dayOffset(offset, hour: hour, minute: minute)
            return Record(
                date: moment,
                timeString: DateHelpers.format12Hour(fromHHmm: String(format: "%02d:%02d", hour, minute)),
                text: text,
                createdAt: moment
            )
        }
    }

    private static var archiveSchedules: [Schedule] {
        let entries: [(Int, Int, Int, String, String, ScheduleColorTheme, String)] = [
            (-9, 15, 0, "분기 리뷰", "업무", .emerald, "chart.bar"),
            (-17, 18, 30, "동네 친구 저녁", "개인", .orange, "fork.knife"),
            (-26, 10, 0, "정기 점검 예약", "개인", .purple, "wrench.and.screwdriver"),
            (-38, 14, 0, "이사 견적 상담", "개인", .gray, "shippingbox")
        ]

        return entries.map { offset, hour, minute, text, calendar, theme, icon in
            let start = String(format: "%02d:%02d", hour, minute)
            let end = String(format: "%02d:%02d", hour + 1, minute)
            return Schedule(
                date: dayOffset(offset, hour: hour, minute: minute),
                timeString: DateHelpers.format12Hour(fromHHmm: start),
                endTimeString: DateHelpers.format12Hour(fromHHmm: end),
                text: text,
                calendarName: calendar,
                colorTheme: theme,
                iconName: icon,
                createdAt: dayOffset(offset, hour: hour - 1, minute: minute)
            )
        }
    }

    private static let upcomingSentinel = "부모님 생신 저녁 식사"

    private static var upcomingSchedules: [Schedule] {
        [
            Schedule(
                date: dayOffset(1, hour: 11, minute: 0),
                timeString: DateHelpers.format12Hour(fromHHmm: "11:00"),
                endTimeString: DateHelpers.format12Hour(fromHHmm: "12:00"),
                text: "스프린트 회고",
                calendarName: "업무",
                locationText: "회의실 A",
                colorTheme: .emerald,
                iconName: "person.2",
                createdAt: Date()
            ),
            Schedule(
                date: dayOffset(1, hour: 19, minute: 30),
                timeString: DateHelpers.format12Hour(fromHHmm: "19:30"),
                endTimeString: DateHelpers.format12Hour(fromHHmm: "20:30"),
                text: "한강 러닝",
                calendarName: "운동",
                locationText: "뚝섬한강공원",
                colorTheme: .blue,
                iconName: "figure.run",
                createdAt: Date()
            ),
            Schedule(
                date: dayOffset(2, hour: 9, minute: 30),
                timeString: DateHelpers.format12Hour(fromHHmm: "09:30"),
                endTimeString: DateHelpers.format12Hour(fromHHmm: "11:30"),
                text: "건강검진",
                calendarName: "개인",
                locationText: "서울건강검진센터",
                colorTheme: .purple,
                iconName: "stethoscope",
                createdAt: Date()
            ),
            Schedule(
                date: dayOffset(3, hour: 14, minute: 0),
                timeString: DateHelpers.format12Hour(fromHHmm: "14:00"),
                endTimeString: DateHelpers.format12Hour(fromHHmm: "15:30"),
                text: "프로젝트 중간 공유",
                calendarName: "업무",
                locationText: "온라인",
                colorTheme: .emerald,
                iconName: "chart.bar",
                createdAt: Date()
            ),
            Schedule(
                date: dayOffset(5, hour: 18, minute: 0),
                timeString: DateHelpers.format12Hour(fromHHmm: "18:00"),
                endTimeString: DateHelpers.format12Hour(fromHHmm: "20:00"),
                text: upcomingSentinel,
                calendarName: "가족",
                locationText: "본가",
                colorTheme: .orange,
                iconName: "birthday.cake",
                createdAt: Date()
            ),
            Schedule(
                date: dayOffset(8, hour: 10, minute: 0),
                timeString: DateHelpers.format12Hour(fromHHmm: "10:00"),
                text: "도서관 대출 반납",
                calendarName: "개인",
                locationText: "시립도서관",
                colorTheme: .gray,
                iconName: "book",
                createdAt: Date()
            )
        ]
    }

    private static var upcomingTodos: [TodoItem] {
        [
            TodoItem(
                date: dayOffset(2),
                text: "검진 전날 밤부터 금식",
                sortOrder: 0,
                createdAt: Date()
            ),
            TodoItem(
                date: dayOffset(5),
                text: "생신 선물 미리 주문하기",
                sortOrder: 0,
                createdAt: Date()
            )
        ]
    }

    private static var sampleRecords: [Record] {
        [
            Record(
                date: dayOffset(-2, hour: 21, minute: 20),
                timeString: DateHelpers.format12Hour(fromHHmm: "21:20"),
                text: "집에 돌아와서 빨래를 돌리고 침대 시트를 갈았다. 별일 아닌데 방이 조금 정돈되니까 마음도 같이 가벼워졌다.",
                createdAt: dayOffset(-2, hour: 21, minute: 20)
            ),
            Record(
                date: dayOffset(-1, hour: 8, minute: 35),
                timeString: DateHelpers.format12Hour(fromHHmm: "08:35"),
                text: "출근길에 새로 생긴 카페에서 라떼를 샀다. 생각보다 덜 달고 고소해서 다음에는 따뜻한 걸로 마셔봐야겠다.",
                createdAt: dayOffset(-1, hour: 8, minute: 35)
            ),
            Record(
                date: dayOffset(0, hour: 9, minute: 12),
                timeString: DateHelpers.format12Hour(fromHHmm: "09:12"),
                text: "아침에 책상 위 영수증을 정리했다. 미뤄둔 일을 하나 끝냈을 뿐인데 하루가 조금 덜 복잡하게 시작되는 느낌.",
                createdAt: dayOffset(0, hour: 9, minute: 12)
            ),
            Record(
                date: dayOffset(0, hour: 11, minute: 48),
                timeString: DateHelpers.format12Hour(fromHHmm: "11:48"),
                text: "엄마가 보내준 김치찌개 사진을 보고 점심 메뉴가 바로 정해졌다. 오늘 저녁에는 집에 있는 두부도 넣어서 끓여야지.",
                createdAt: dayOffset(0, hour: 11, minute: 48)
            ),
            Record(
                date: dayOffset(0, hour: 15, minute: 5),
                timeString: DateHelpers.format12Hour(fromHHmm: "15:05"),
                text: "오후에 잠깐 집중이 끊겨서 10분 정도 밖을 걸었다. 돌아오니까 머리가 맑아져서 남은 일도 금방 정리됐다.",
                createdAt: dayOffset(0, hour: 15, minute: 5)
            ),
            Record(
                date: dayOffset(1, hour: 10, minute: 20),
                timeString: DateHelpers.format12Hour(fromHHmm: "10:20"),
                text: "내일 오전에는 은행 앱에서 자동이체 내역을 확인해야 한다. 지난달보다 고정 지출이 조금 늘어난 것 같아서 한번 봐두기.",
                createdAt: dayOffset(1, hour: 10, minute: 20)
            )
        ]
    }

    private static var sampleSchedules: [Schedule] {
        [
            Schedule(
                date: dayOffset(-1, hour: 14, minute: 0),
                timeString: DateHelpers.format12Hour(fromHHmm: "14:00"),
                endTimeString: DateHelpers.format12Hour(fromHHmm: "15:00"),
                text: "치과 정기 검진",
                calendarName: "개인",
                locationText: "연세봄치과",
                colorTheme: .purple,
                iconName: "cross.case",
                createdAt: dayOffset(-1, hour: 13, minute: 30)
            ),
            Schedule(
                date: dayOffset(0, hour: 10, minute: 0),
                timeString: DateHelpers.format12Hour(fromHHmm: "10:00"),
                endTimeString: DateHelpers.format12Hour(fromHHmm: "11:00"),
                text: "팀 주간 미팅",
                calendarName: "업무",
                locationText: "회의실 B",
                colorTheme: .emerald,
                iconName: "person.2",
                createdAt: dayOffset(0, hour: 8, minute: 50)
            ),
            Schedule(
                date: dayOffset(0, hour: 13, minute: 30),
                timeString: DateHelpers.format12Hour(fromHHmm: "13:30"),
                endTimeString: DateHelpers.format12Hour(fromHHmm: "14:30"),
                text: "민지랑 점심",
                calendarName: "개인",
                locationText: "을지로",
                colorTheme: .orange,
                iconName: "fork.knife",
                createdAt: dayOffset(0, hour: 8, minute: 55)
            ),
            Schedule(
                date: dayOffset(1, hour: 16, minute: 0),
                timeString: DateHelpers.format12Hour(fromHHmm: "16:00"),
                endTimeString: DateHelpers.format12Hour(fromHHmm: "17:00"),
                text: "요가 수업",
                calendarName: "운동",
                locationText: "마루 스튜디오",
                colorTheme: .blue,
                iconName: "figure.yoga",
                createdAt: dayOffset(0, hour: 17, minute: 45)
            )
        ]
    }

    private static var sampleTodos: [TodoItem] {
        [
            TodoItem(
                date: dayOffset(-1),
                text: "택배 반품 접수하기",
                completed: true,
                sortOrder: 0,
                createdAt: dayOffset(-1, hour: 9, minute: 10)
            ),
            TodoItem(
                date: dayOffset(0),
                text: "전기요금 자동이체 확인",
                sortOrder: 0,
                createdAt: dayOffset(0, hour: 8, minute: 40)
            ),
            TodoItem(
                date: dayOffset(0),
                text: "저녁 장보기: 두부, 대파, 우유",
                sortOrder: 1,
                createdAt: dayOffset(0, hour: 8, minute: 41)
            ),
            TodoItem(
                date: dayOffset(1),
                text: "운동복 세탁해서 챙겨두기",
                sortOrder: 0,
                createdAt: dayOffset(0, hour: 17, minute: 0)
            )
        ]
    }

    @MainActor
    private static func cleanupOldDesignSamples(context: ModelContext) {
        let oldRecordSnippets = [
            "디자인 샘플",
            "검색창, 일정 pill",
            "입력 바와 하단 탭",
            "타임라인 중간 밀도",
            "액션 아이템은 할 일로",
            "프로토타입 포인트"
        ]
        let oldScheduleTitles = [
            // Scaffolding for looking at the in-progress treatment; the seeder that made
            // it is gone, so this clears the row it left in already-seeded stores.
            "진행 중 확인용",
            "제품 방향성 리뷰",
            "디자인 QA 세션",
            "점심 산책",
            "릴리즈 체크인"
        ]
        let oldTodoTitles = [
            "검색 결과 빈 상태 문구 다듬기",
            "타임라인 카드 간격과 축 라인 정렬 확인",
            "하단 입력 바가 키보드와 탭 바 사이에서 자연스러운지 보기",
            "인사이트 탭 샘플 차트 밀도 확인"
        ]

        if let records = try? context.fetch(FetchDescriptor<Record>()) {
            for record in records where oldRecordSnippets.contains(where: { record.text.contains($0) }) {
                context.delete(record)
            }
        }
        if let schedules = try? context.fetch(FetchDescriptor<Schedule>()) {
            for schedule in schedules where oldScheduleTitles.contains(schedule.text) {
                context.delete(schedule)
            }
        }
        if let todos = try? context.fetch(FetchDescriptor<TodoItem>()) {
            for todo in todos where oldTodoTitles.contains(todo.text) {
                context.delete(todo)
            }
        }
    }

    private static func dayOffset(_ days: Int, hour: Int = 9, minute: Int = 0) -> Date {
        let base = DateHelpers.calendar.date(byAdding: .day, value: days, to: Date()) ?? Date()
        let start = DateHelpers.startOfDay(base)
        return DateHelpers.calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: start) ?? start
    }
    #endif
}
