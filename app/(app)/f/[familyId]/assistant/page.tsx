import { requireFamily } from "@/lib/families/page";
import { ChatPage } from "@/components/assistant/chat-page";

export default async function AssistantPage({ params }: { params: Promise<{ familyId: string }> }) {
  const { familyId } = await params;
  await requireFamily(familyId);
  return <ChatPage />;
}
