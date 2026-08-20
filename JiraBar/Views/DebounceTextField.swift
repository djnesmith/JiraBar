//
//  DebounceTextField.swift
//  jiraBar
//
//  Created by Pavel Makhov on 2024-09-30.
//

import SwiftUI
import Combine

struct DebounceTextField: View {
    
    @State var publisher = PassthroughSubject<String, Never>()
    
    @State var label: String
    @Binding var value: String
    /// `.vertical` makes it a multi-line box, paired with `lineLimit` — what the comment dialogs
    /// need. The Preferences fields stay single-line.
    var axis: Axis = .horizontal
    var lineLimit: ClosedRange<Int>?
    /// Focus binding for callers that key behaviour off focus. Passed in rather than applied by the
    /// caller because `.focused` has to land on the real text field, not on a wrapper around it.
    var focus: FocusState<Bool>.Binding?
    var valueChanged: ((_ value: String) -> Void)?

    @State var debounceSeconds = 0.5

    var body: some View {
        focusable
            .disableAutocorrection(true)
            .textFieldStyle(.roundedBorder)
            .onChange(of: value) { value in
                publisher.send(value)
            }
            .onReceive(
                publisher.debounce(
                    for: .seconds(debounceSeconds),
                    scheduler: DispatchQueue.main
                )
            ) { value in
                if let valueChanged = valueChanged {
                    valueChanged(value)
                }
            }
    }

    @ViewBuilder
    private var focusable: some View {
        if let focus {
            field.focused(focus)
        } else {
            field
        }
    }

    @ViewBuilder
    private var field: some View {
        if let lineLimit {
            TextField(label, text: $value, axis: axis).lineLimit(lineLimit)
        } else {
            TextField(label, text: $value, axis: axis)
        }
    }
}

//#Preview {
//    DebounceTextField()
//}
