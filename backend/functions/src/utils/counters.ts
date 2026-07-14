import { DocumentReference, FieldValue } from "firebase-admin/firestore";

export async function adjustCounter(
  ref: DocumentReference,
  field: string,
  delta: number
): Promise<void> {
  await ref.update({ [field]: FieldValue.increment(delta) });
}
