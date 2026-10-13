> Final-source checkpoint: all 143 signed units, Arabic and English native match-card regressions, Release build/static analysis and 32-marker audit passed after the Arabic CMS-key fix. See IOS_TEST_EXECUTION_REPORT.md and OCT13-REQUIREMENTS.md for current scoped acceptance; preliminary pending statements below are preserved history. The full original QA plan remains incomplete.

# October13 issue and deletion reconciliation

Status: baseline-equivalent public workflow extraction wired; focused RED tests awaiting execution. No reconciliation fix or runtime success is claimed yet.

The IssueComposer calls IssueSubmissionCoordinator.submit through its existing native Submit action. The coordinator currently performs the same single UserService.createIssue operation as before. The parent ReportAnIssueView owns this coordinator so state can later survive composer dismissal/reopening. Draft fields are explicit type/title/description, and the existing issue list is supplied as baseline evidence. Original input validation and managed error presentation remain unchanged.

DeleteAccountView now calls the root-owned SessionManager.deleteAccount(reasonId:), whose baseline implementation performs one DELETE and ends the session only if the captured session still owns the operation. The separate unscoped endDeletedSession callback was removed from the view.

Focused tests use real APIClient/UserService/AuthService and StubHTTP only, with synthetic tokens, issue text and account identity. No live backend mutation, photos or credentials are included. Tests expect (1) a lost report acknowledgement to be confirmed only by a new exact issue ID, never an old identical report; (2) uncertain deletion followed by explicit saved-session rejection to clear local authentication without a second DELETE.

Root owns SessionManager and APIClient implementation. This worker owns issue coordinator and view wiring only. Existing password changes and confirmation-message edits are preserved.
