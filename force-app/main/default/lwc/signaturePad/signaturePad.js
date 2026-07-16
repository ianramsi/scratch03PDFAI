import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { reduceErrors } from 'c/errorUtils';
//import { reduceErrors } from '../errorUtils/errorUtils';
import saveSignature from '@salesforce/apex/FormSignatureController.saveSignature';

/**
 * signaturePad
 * ----------------------------------------------------------------------------
 * A canvas the user draws a signature on. On "Save", exports the canvas to a
 * PNG, sends the base64 to Apex which creates a ContentVersion, and emits a
 * `signed` event with { role, fieldId, contentVersionId } so the parent can
 * record it against the submission.
 *
 * DESIGN:
 *  - Pure pointer-driven drawing (mouse + touch via Pointer Events). No external
 *    library needed for an MVP signature.
 *  - The PNG upload goes through Apex (not raw ContentVersion via LDS) because we
 *    base64-encode on the client and want the Apex layer to enforce size/FLS and
 *    keep the create logic server-side.
 *  - Size guard: signatures are tiny; we still cap to avoid accidental huge blobs.
 */
export default class SignaturePad extends LightningElement {
    @api role;        // 'engineer' | 'supervisor'
    @api fieldId;     // schema signature field id, e.g. 'f_sig_engineer'
    @api disabled = false;

    _ctx;
    _drawing = false;
    _hasInk = false;
    isSaving = false;

    renderedCallback() {
        if (this._ctx) return; // initialize once
        const canvas = this.refs.canvas;
        if (!canvas) return;
        // Match the backing store to the displayed size for crisp lines.
        canvas.width = canvas.offsetWidth;
        canvas.height = canvas.offsetHeight;
        const ctx = canvas.getContext('2d');
        ctx.lineWidth = 2;
        ctx.lineCap = 'round';
        ctx.strokeStyle = '#1a1a1a';
        this._ctx = ctx;
    }

    // ---- drawing handlers (Pointer Events cover mouse + touch + pen) ----
    handlePointerDown(evt) {
        if (this.disabled) return;
        this._drawing = true;
        const { x, y } = this.pos(evt);
        this._ctx.beginPath();
        this._ctx.moveTo(x, y);
        // Capture so we keep receiving moves even if the pointer leaves the canvas.
        this.refs.canvas.setPointerCapture(evt.pointerId);
    }

    handlePointerMove(evt) {
        if (!this._drawing) return;
        const { x, y } = this.pos(evt);
        this._ctx.lineTo(x, y);
        this._ctx.stroke();
        this._hasInk = true;
    }

    handlePointerUp(evt) {
        this._drawing = false;
        try {
            this.refs.canvas.releasePointerCapture(evt.pointerId);
        } catch (e) {
            // releasing a non-captured pointer can throw; safe to ignore.
        }
    }

    pos(evt) {
        const rect = this.refs.canvas.getBoundingClientRect();
        return { x: evt.clientX - rect.left, y: evt.clientY - rect.top };
    }

    handleClear() {
        if (!this._ctx) return;
        const c = this.refs.canvas;
        this._ctx.clearRect(0, 0, c.width, c.height);
        this._hasInk = false;
    }

    async handleSave() {
        if (!this._hasInk) {
            this.toast('Empty signature', 'Please draw your signature first.', 'warning');
            return;
        }
        this.isSaving = true;
        try {
            // Export canvas -> PNG data URL -> strip prefix to get base64.
            const dataUrl = this.refs.canvas.toDataURL('image/png');
            const base64 = dataUrl.split(',')[1];

            const fileName = `signature_${this.role}_${Date.now()}.png`;
            const contentVersionId = await saveSignature({
                fileName,
                base64Data: base64
            });

            // Tell the parent so it can call recordSignature against the submission.
            this.dispatchEvent(
                new CustomEvent('signed', {
                    detail: {
                        role: this.role,
                        fieldId: this.fieldId,
                        contentVersionId
                    }
                })
            );
            this.toast('Signature saved', '', 'success');
        } catch (error) {
            this.toast('Could not save signature', reduceErrors(error).join(', '), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}