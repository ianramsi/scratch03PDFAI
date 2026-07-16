/**
 * FormStateMachine
 * ----------------------------------------------------------------------------
 * The SINGLE authoritative gate for Form_Submission__c.Status__c transitions.
 *
 * WHY APEX-ONLY (no Validation Rules / Flow):
 *  A reject is not a simple field change -- it must ATOMICALLY:
 *    (a) flip status to Rejected (then the engineer revises back to Draft),
 *    (b) void the existing signatures (they signed a version now being changed),
 *    (c) increment Revision_Number__c.
 *  Doing (a)+(b)+(c) atomically and conditionally is awkward and brittle across
 *  Validation Rules + Flow. Centralizing here keeps the rules in one readable,
 *  testable place and guarantees no partial transitions.
 *
 * LEGAL TRANSITIONS (state machine):
 *    Draft      -> Submitted   (engineer submits a filled, signed form)
 *    Submitted  -> Approved    (supervisor verifies + signs)         [terminal-ish]
 *    Submitted  -> Rejected    (supervisor rejects with comment)
 *    Rejected   -> Draft       (engineer reopens to revise)
 *  Anything else is illegal and throws.
 *
 *  Approved is effectively terminal for the MVP: the PDF is generated and becomes
 *  the official record. We do NOT allow Approved -> anything.
 *
 * SHARING:
 *  `inherited sharing` -- this class mutates records but is always invoked from a
 *  `with sharing` service, so it must run in the caller's (the user's) context.
 *  We do NOT want it to silently become `without sharing`.
 *
 * BULK NOTE:
 *  Methods accept single records because submission transitions are inherently
 *  user-by-user UI actions, not bulk loads. If a bulk path is ever needed, the
 *  void-signature DML below must be refactored to collect across submissions
 *  first. Called out explicitly so a future bulk caller doesn't introduce a
 *  SOQL/DML-in-loop pattern by accident.
 */
public inherited sharing class FormStateMachine {

    // Status string constants -> avoid magic strings and typos across the codebase.
    public static final String DRAFT     = 'Draft';
    public static final String SUBMITTED = 'Submitted';
    public static final String APPROVED  = 'Approved';
    public static final String REJECTED  = 'Rejected';

    // Allowed transitions as a map of from -> set of valid to-states.
    private static final Map<String, Set<String>> ALLOWED = new Map<String, Set<String>>{
        DRAFT     => new Set<String>{ SUBMITTED },
        SUBMITTED => new Set<String>{ APPROVED, REJECTED },
        REJECTED  => new Set<String>{ DRAFT },
        APPROVED  => new Set<String>()  // terminal
    };

    /**
     * Engineer submits a Draft. Caller is responsible for having ensured the form
     * is fully filled and the engineer signature row exists (UI/service concern).
     */
    public static void submit(Id submissionId) {
        Form_Submission__c sub = load(submissionId);
        assertTransition(sub.Status__c, SUBMITTED);
        sub.Status__c = SUBMITTED;
        sub.Submitted_At__c = System.now();
        // USER_MODE DML so the running engineer must actually have edit rights.
        update as user new List<Form_Submission__c>{ sub };
    }

    /**
     * Supervisor approves. The supervisor signature is expected to already be
     * captured by the service before this is called. PDF finalize is triggered
     * by the SERVICE after this returns successfully -- not here, to keep the
     * state machine free of callouts (a callout here would block other DML and
     * complicate rollback).
     */
    public static void approve(Id submissionId, Id supervisorUserId) {
        Form_Submission__c sub = load(submissionId);
        assertTransition(sub.Status__c, APPROVED);
        sub.Status__c = APPROVED;
        sub.Approved_At__c = System.now();
        sub.Supervisor__c = supervisorUserId;
        update as user new List<Form_Submission__c>{ sub };
    }

    /**
     * Supervisor rejects with a mandatory comment. Atomically:
     *   - sets status Rejected,
     *   - records the comment,
     *   - voids all current signatures on the submission (they signed content
     *     that is about to be revised),
     *   - increments revision number.
     * All DML in one transaction; if any part fails the whole reject rolls back.
     */
    public static void reject(Id submissionId, Id supervisorUserId, String comment) {
        if (String.isBlank(comment)) {
            // Business rule: a rejection must tell the engineer what to fix.
            throw new FormCalloutException('VALIDATION_FAILED', 'Rejection requires a comment.');
        }

        Form_Submission__c sub = load(submissionId);
        assertTransition(sub.Status__c, REJECTED);

        sub.Status__c = REJECTED;
        sub.Rejection_Comment__c = comment;
        sub.Supervisor__c = supervisorUserId;
        // Increment using current value; null-safe via ?? (Spring '24+).
        sub.Revision_Number__c = (sub.Revision_Number__c ?? 0) + 1;

        // Void existing, non-void signatures. Query is OUTSIDE any loop (bulk-safe
        // for the single-submission case). USER_MODE enforces FLS/CRUD.
        List<Form_Signature__c> sigs = [
            SELECT Id, Is_Void__c
            FROM Form_Signature__c
            WHERE Form_Submission__c = :submissionId
              AND Is_Void__c = false
            WITH USER_MODE
        ];
        for (Form_Signature__c s : sigs) {
            s.Is_Void__c = true;
        }

        // One DML per object type. Both in the same transaction -> atomic.
        update as user new List<Form_Submission__c>{ sub };
        if (!sigs.isEmpty()) {
            update as user sigs;
        }
    }

    /**
     * Engineer reopens a Rejected submission to revise it. Status returns to Draft.
     * Signatures were already voided at reject time; the engineer will re-sign
     * before re-submitting.
     */
    public static void reopenForRevision(Id submissionId) {
        Form_Submission__c sub = load(submissionId);
        assertTransition(sub.Status__c, DRAFT);
        sub.Status__c = DRAFT;
        update as user new List<Form_Submission__c>{ sub };
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /** Throws unless from->to is in the ALLOWED map. Central guard for every path. */
    private static void assertTransition(String fromStatus, String toStatus) {
        Set<String> targets = ALLOWED.get(fromStatus);
        if (targets == null || !targets.contains(toStatus)) {
            throw new FormCalloutException(
                'VALIDATION_FAILED',
                'Illegal status transition: ' + fromStatus + ' -> ' + toStatus + '.'
            );
        }
    }

    /** Load a single submission with the fields the machine needs. USER_MODE so a
     *  user cannot transition a record they can't see/edit. */
    private static Form_Submission__c load(Id submissionId) {
        List<Form_Submission__c> rows = [
            SELECT Id, Status__c, Revision_Number__c
            FROM Form_Submission__c
            WHERE Id = :submissionId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw new FormCalloutException('VALIDATION_FAILED', 'Submission not found or not accessible.');
        }
        return rows[0];
    }
}