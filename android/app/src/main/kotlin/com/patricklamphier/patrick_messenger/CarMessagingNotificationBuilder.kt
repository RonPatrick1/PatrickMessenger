package com.patricklamphier.patrick_messenger

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput

/**
 * Builds the Android Auto-compatible `NotificationCompat.MessagingStyle`
 * notification for a room: a reply action with an attached `RemoteInput`
 * and a mark-as-read action, both routed to [CarReplyService] so they work
 * without the app's UI process alive. Uses a notification ID derived from
 * the room ID (not the per-event ID the phone-side notification uses) so
 * multiple messages in the same room extend one conversation notification
 * instead of stacking a separate one per message.
 */
object CarMessagingNotificationBuilder {
    private const val CHANNEL_ID = "messages_with_sound_v1"
    const val EXTRA_ROOM_ID = "room_id"
    const val EXTRA_PHONE_NOTIFICATION_ID = "phone_notification_id"
    const val REMOTE_INPUT_RESULT_KEY = "car_reply_text"

    fun carNotificationId(roomId: String): Int = ("car_$roomId").hashCode() and 0x7fffffff

    fun show(
        context: Context,
        roomId: String,
        phoneNotificationId: Int,
        senderId: String,
        senderName: String,
        conversationTitle: String,
        isGroupConversation: Boolean,
        body: String,
    ) {
        val notificationId = carNotificationId(roomId)
        val manager = NotificationManagerCompat.from(context)

        val self = Person.Builder().setName("Me").build()
        val sender = Person.Builder().setKey(senderId).setName(senderName).build()

        val existingNotification = manager.activeNotifications
            .firstOrNull { it.id == notificationId }
            ?.notification
        val style = existingNotification
            ?.let { NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(it) }
            ?: NotificationCompat.MessagingStyle(self)
        style.isGroupConversation = isGroupConversation
        style.conversationTitle = if (isGroupConversation) conversationTitle else null
        style.addMessage(body, System.currentTimeMillis(), sender)

        val replyAction = buildReplyAction(context, roomId, phoneNotificationId, notificationId)
        val markReadAction = buildMarkReadAction(context, roomId, phoneNotificationId, notificationId)

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setStyle(style)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .addAction(replyAction)
            .addAction(markReadAction)
            .build()

        manager.notify(notificationId, notification)
    }

    fun clear(context: Context, roomId: String) {
        NotificationManagerCompat.from(context).cancel(carNotificationId(roomId))
    }

    private fun buildReplyAction(
        context: Context,
        roomId: String,
        phoneNotificationId: Int,
        notificationId: Int,
    ): NotificationCompat.Action {
        val intent = Intent(context, CarReplyService::class.java).apply {
            action = CarReplyService.ACTION_REPLY
            data = Uri.parse("carreply://room/$roomId")
            putExtra(EXTRA_ROOM_ID, roomId)
            putExtra(EXTRA_PHONE_NOTIFICATION_ID, phoneNotificationId)
        }
        val pendingIntent = PendingIntent.getService(
            context,
            notificationId,
            intent,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val remoteInput = RemoteInput.Builder(REMOTE_INPUT_RESULT_KEY)
            .setLabel("Reply")
            .build()
        return NotificationCompat.Action.Builder(
            R.drawable.ic_notification,
            "Reply",
            pendingIntent,
        )
            .addRemoteInput(remoteInput)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
            .setShowsUserInterface(false)
            .setAllowGeneratedReplies(false)
            .build()
    }

    private fun buildMarkReadAction(
        context: Context,
        roomId: String,
        phoneNotificationId: Int,
        notificationId: Int,
    ): NotificationCompat.Action {
        val intent = Intent(context, CarReplyService::class.java).apply {
            action = CarReplyService.ACTION_MARK_READ
            data = Uri.parse("carreply://room/$roomId/read")
            putExtra(EXTRA_ROOM_ID, roomId)
            putExtra(EXTRA_PHONE_NOTIFICATION_ID, phoneNotificationId)
        }
        val pendingIntent = PendingIntent.getService(
            context,
            notificationId + 1,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Action.Builder(
            R.drawable.ic_notification,
            "Mark as read",
            pendingIntent,
        )
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_MARK_AS_READ)
            .setShowsUserInterface(false)
            .build()
    }
}
