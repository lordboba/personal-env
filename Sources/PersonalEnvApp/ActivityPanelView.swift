import SwiftUI
import PersonalEnvCore

struct ActivityPanelView: View {
    let activeApprovals: [AuthorizationGrant]
    let auditEvents: [AuditEvent]
    let onRefreshApprovals: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Activity", systemImage: "clock")
                    .font(.headline)
                    .foregroundStyle(EnvTheme.ink)
                Spacer()
                Button(action: onRefreshApprovals) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh approvals")
            }

            if !activeApprovals.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Approvals")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(EnvTheme.muted)
                    ForEach(activeApprovals.prefix(4)) { grant in
                        ApprovalGrantRow(grant: grant)
                    }
                }
            }

            if auditEvents.isEmpty {
                Text("No recorded activity")
                    .font(.caption)
                    .foregroundStyle(EnvTheme.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("History")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(EnvTheme.muted)
                    ForEach(auditEvents.sorted(by: { $0.occurredAt > $1.occurredAt }).prefix(8)) { event in
                        AuditEventRow(event: event)
                    }
                }
            }
        }
        .padding(18)
    }
}

private struct ApprovalGrantRow: View {
    let grant: AuthorizationGrant

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: grant.subject.isScoped ? "scope" : "lock.open")
                    .foregroundStyle(EnvTheme.accent)
                    .frame(width: 18)
                Text(approvalTitle(grant.subject))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(EnvTheme.ink)
                    .lineLimit(1)
                Spacer()
            }
            Text("Expires \(grant.expiresAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(EnvTheme.muted)
            if let detail = approvalDetail(grant.subject) {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(EnvTheme.muted)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(EnvTheme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(EnvTheme.separator.opacity(0.45), lineWidth: 1)
        )
    }

    private func approvalTitle(_ subject: ApprovalSubject) -> String {
        let capability = subject.capability == .readSecrets ? "Read" : "Write"
        if let requester = subject.requester {
            return "\(capability) for \(requester)"
        }
        return subject.isScoped ? "\(capability) scoped approval" : "\(capability) approval"
    }

    private func approvalDetail(_ subject: ApprovalSubject) -> String? {
        var parts: [String] = []
        if let keySet = subject.keySet, !keySet.isEmpty {
            parts.append(keySet.joined(separator: ", "))
        }
        if let destination = subject.destination {
            parts.append(approvalDestinationText(destination))
        }
        if let command = subject.command {
            parts.append(command)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func approvalDestinationText(_ destination: ApprovalDestination) -> String {
        switch destination {
        case .file(let path):
            return path
        case .stdout:
            return "stdout"
        case .clipboard:
            return "clipboard"
        case .app:
            return "app"
        }
    }
}

private struct AuditEventRow: View {
    let event: AuditEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: auditIcon(event.type))
                .foregroundStyle(auditColor(event.type))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.summary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(EnvTheme.ink)
                    .lineLimit(2)
                Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(EnvTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func auditIcon(_ type: AuditEvent.EventType) -> String {
        switch type {
        case .importSecrets:
            return "arrow.down.to.line"
        case .exportSecrets:
            return "arrow.up.to.line"
        case .scan:
            return "doc.text.magnifyingglass"
        case .approval:
            return "checkmark.shield"
        case .revoke:
            return "xmark.shield"
        case .failedAuth:
            return "exclamationmark.triangle"
        case .vaultCreated:
            return "folder.badge.plus"
        case .vaultRenamed:
            return "pencil"
        case .vaultDeleted:
            return "trash"
        case .secretUpdated:
            return "key.fill"
        case .secretDeleted:
            return "key.slash"
        }
    }

    private func auditColor(_ type: AuditEvent.EventType) -> Color {
        switch type {
        case .failedAuth, .revoke, .vaultDeleted, .secretDeleted:
            return EnvTheme.red
        case .approval, .importSecrets, .secretUpdated, .vaultCreated:
            return EnvTheme.green
        case .exportSecrets, .scan, .vaultRenamed:
            return EnvTheme.accent
        }
    }
}
