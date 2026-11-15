// SwipeClean for Android – pick a month, swipe LEFT = mark for deletion, RIGHT = keep.
// Nothing is removed until you tap "Delete all" and confirm the system prompt.

package com.example.swipeclean

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import coil.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.YearMonth
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.math.abs

// ---------------------------------------------------------------- Model

data class Photo(val id: Long, val uri: Uri, val dateMs: Long, val favorite: Boolean)

data class Month(val key: Int, val title: String, val photos: List<Photo>)

class PhotoStore(private val context: Context) {
    private val prefs = context.getSharedPreferences("swipeclean", Context.MODE_PRIVATE)

    var loaded by mutableStateOf(false)
        private set
    var months by mutableStateOf(listOf<Month>())
        private set
    var kept by mutableStateOf(loadKept())
        private set
    var trash by mutableStateOf(listOf<Photo>())
        private set
    var trashIds by mutableStateOf(setOf<Long>())
        private set
    var favorites by mutableStateOf(mapOf<Long, Boolean>())
        private set
    var generation by mutableIntStateOf(0)   // bumps whenever photos were really removed
        private set

    suspend fun load() {
        val result = withContext(Dispatchers.IO) { queryMonths() }
        months = result
        loaded = true
    }

    private fun queryMonths(): List<Month> {
        val photos = ArrayList<Photo>()
        val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DATE_TAKEN,
            MediaStore.Images.Media.DATE_ADDED,
            MediaStore.MediaColumns.IS_FAVORITE,
        )
        context.contentResolver.query(collection, projection, null, null, null)?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
            val takenCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_TAKEN)
            val addedCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED)
            val favCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.IS_FAVORITE)
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idCol)
                val taken = cursor.getLong(takenCol)
                val ms = if (taken > 0) taken else cursor.getLong(addedCol) * 1000
                photos.add(
                    Photo(id, ContentUris.withAppendedId(collection, id), ms, cursor.getInt(favCol) == 1)
                )
            }
        }
        photos.sortByDescending { it.dateMs }
        val zone = ZoneId.systemDefault()
        val formatter = DateTimeFormatter.ofPattern("LLLL yyyy")
        return photos
            .groupBy {
                val date = Instant.ofEpochMilli(it.dateMs).atZone(zone)
                date.year * 100 + date.monthValue
            }
            .entries
            .sortedByDescending { it.key }
            .map { entry ->
                Month(
                    entry.key,
                    YearMonth.of(entry.key / 100, entry.key % 100).format(formatter),
                    entry.value,
                )
            }
    }

    fun month(key: Int): Month? = months.firstOrNull { it.key == key }

    fun reviewedCount(month: Month): Int =
        month.photos.count { it.id in kept || it.id in trashIds }

    val doneMonthCount: Int
        get() = months.count { reviewedCount(it) == it.photos.size }

    fun unreviewed(key: Int): List<Photo> =
        month(key)?.photos?.filter { it.id !in kept && it.id !in trashIds } ?: emptyList()

    fun keep(photo: Photo) {
        kept = kept + photo.id
        saveKept()
    }

    fun markTrash(photo: Photo) {
        if (photo.id in trashIds) return
        trashIds = trashIds + photo.id
        trash = trash + photo
    }

    /** Undo: the photo counts as not looked at again. */
    fun unreview(photo: Photo) {
        if (photo.id in trashIds) {
            trashIds = trashIds - photo.id
            trash = trash.filter { it.id != photo.id }
        }
        if (photo.id in kept) {
            kept = kept - photo.id
            saveKept()
        }
    }

    /** Take a photo back out of the trash (counts as "keep"). */
    fun restore(photo: Photo) {
        trashIds = trashIds - photo.id
        trash = trash.filter { it.id != photo.id }
        keep(photo)
    }

    /** Lets you go through a month again. Photos already marked for deletion stay marked. */
    fun resetMonth(key: Int) {
        val ids = month(key)?.photos?.map { it.id }?.toSet() ?: return
        kept = kept - ids
        saveKept()
    }

    fun resetAll() {
        kept = emptySet()
        saveKept()
    }

    /** Call after the system confirmed that the marked photos were removed. */
    fun removeTrashed() {
        val gone = trashIds
        months = months.mapNotNull { month ->
            val rest = month.photos.filter { it.id !in gone }
            if (rest.isEmpty()) null else month.copy(photos = rest)
        }
        trash = emptyList()
        trashIds = emptySet()
        generation++
    }

    fun isFavorite(photo: Photo): Boolean = favorites[photo.id] ?: photo.favorite

    fun setFavorite(id: Long, value: Boolean) {
        favorites = favorites + (id to value)
    }

    private fun loadKept(): Set<Long> =
        (prefs.getString("kept", "") ?: "")
            .split(',')
            .mapNotNull { it.toLongOrNull() }
            .toSet()

    private fun saveKept() {
        prefs.edit().putString("kept", kept.joinToString(",")).apply()
    }
}

// ---------------------------------------------------------------- Activity

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val store = PhotoStore(applicationContext)
        setContent {
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
                Surface(modifier = Modifier.fillMaxSize()) {
                    Box(modifier = Modifier.safeDrawingPadding()) {
                        App(store)
                    }
                }
            }
        }
    }
}

@Composable
fun App(store: PhotoStore) {
    val context = LocalContext.current
    val permission =
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES
        else Manifest.permission.READ_EXTERNAL_STORAGE

    var granted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
        )
    }
    val permissionLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }

    LaunchedEffect(Unit) { if (!granted) permissionLauncher.launch(permission) }
    LaunchedEffect(granted) { if (granted) store.load() }

    var monthKey by remember { mutableStateOf<Int?>(null) }
    var showTrash by remember { mutableStateOf(false) }

    val trashLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
            if (result.resultCode == Activity.RESULT_OK) {
                store.removeTrashed()
                showTrash = false
            }
        }
    val confirmDelete: () -> Unit = {
        if (store.trash.isNotEmpty()) {
            // Moves the photos to the system trash, where they are removed after 30 days.
            val request = MediaStore.createTrashRequest(
                context.contentResolver, store.trash.map { it.uri }, true
            )
            trashLauncher.launch(IntentSenderRequest.Builder(request.intentSender).build())
        }
    }

    val currentMonth = monthKey
    when {
        !granted -> PermissionScreen(
            onRetry = { permissionLauncher.launch(permission) },
            onSettings = {
                context.startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", context.packageName, null),
                    )
                )
            },
        )

        showTrash -> TrashScreen(store, onBack = { showTrash = false }, onDelete = confirmDelete)

        currentMonth != null -> key(currentMonth) {
            DeckScreen(
                store = store,
                monthKey = currentMonth,
                onBack = { monthKey = null },
                onShowTrash = { showTrash = true },
            )
        }

        else -> MonthListScreen(
            store = store,
            onOpen = { monthKey = it },
            onShowTrash = { showTrash = true },
        )
    }
}

// ---------------------------------------------------------------- Shared pieces

@Composable
fun TopBar(title: String, onBack: (() -> Unit)?, action: @Composable () -> Unit = {}) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (onBack != null) {
            TextButton(onClick = onBack) { Text("‹ Back") }
        } else {
            Spacer(Modifier.size(12.dp))
        }
        Text(
            text = title,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.weight(1f),
        )
        action()
    }
}

@Composable
fun TrashBar(count: Int, onClick: () -> Unit) {
    if (count == 0) return
    Button(
        onClick = onClick,
        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFD32F2F), contentColor = Color.White),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Text("Review & delete $count")
    }
}

@Composable
fun PermissionScreen(onRetry: () -> Unit, onSettings: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("SwipeClean needs access to your photos.", textAlign = TextAlign.Center)
        Spacer(Modifier.height(16.dp))
        Button(onClick = onRetry) { Text("Allow access") }
        TextButton(onClick = onSettings) { Text("Open settings") }
    }
}

// ---------------------------------------------------------------- Month list

@Composable
fun MonthListScreen(store: PhotoStore, onOpen: (Int) -> Unit, onShowTrash: () -> Unit) {
    var confirmReset by remember { mutableStateOf(false) }

    Column(modifier = Modifier.fillMaxSize()) {
        TopBar(title = "SwipeClean", onBack = null) {
            TextButton(onClick = { confirmReset = true }) { Text("Reset") }
        }
        if (!store.loaded) {
            Box(modifier = Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        } else if (store.months.isEmpty()) {
            Box(modifier = Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Text("No photos found")
            }
        } else {
            Text(
                text = "${store.doneMonthCount} of ${store.months.size} months done",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 6.dp),
            )
            LazyColumn(modifier = Modifier.weight(1f)) {
                items(store.months, key = { it.key }) { month ->
                    MonthRow(
                        title = month.title,
                        reviewed = store.reviewedCount(month),
                        total = month.photos.size,
                        onClick = { onOpen(month.key) },
                    )
                    HorizontalDivider()
                }
            }
        }
        TrashBar(store.trash.size, onShowTrash)
    }

    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            title = { Text("Reset all progress?") },
            text = { Text("Every month is marked as not reviewed again. No photos are changed.") },
            confirmButton = {
                TextButton(onClick = {
                    store.resetAll()
                    confirmReset = false
                }) { Text("Reset") }
            },
            dismissButton = { TextButton(onClick = { confirmReset = false }) { Text("Cancel") } },
        )
    }
}

@Composable
fun MonthRow(title: String, reviewed: Int, total: Int, onClick: () -> Unit) {
    val done = reviewed == total
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(
                text = if (done) "Done · $total photos" else "$reviewed of $total reviewed",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (!done && reviewed > 0) {
                Spacer(Modifier.height(6.dp))
                LinearProgressIndicator(
                    progress = { reviewed.toFloat() / total.toFloat() },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
        if (done) {
            Spacer(Modifier.size(12.dp))
            Icon(Icons.Filled.CheckCircle, contentDescription = "Done", tint = Color(0xFF2E7D32))
        }
    }
}

// ---------------------------------------------------------------- Swiping through one month

@Composable
fun DeckScreen(store: PhotoStore, monthKey: Int, onBack: () -> Unit, onShowTrash: () -> Unit) {
    val context = LocalContext.current
    BackHandler(onBack = onBack)

    var queue by remember { mutableStateOf(store.unreviewed(monthKey)) }
    var index by remember { mutableIntStateOf(0) }
    var undoFloor by remember { mutableIntStateOf(0) }   // can't undo past photos that were removed
    LaunchedEffect(store.generation) { undoFloor = index }

    var pendingFavorite by remember { mutableStateOf<Pair<Long, Boolean>?>(null) }
    val favoriteLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
            val pending = pendingFavorite
            if (result.resultCode == Activity.RESULT_OK && pending != null) {
                store.setFavorite(pending.first, pending.second)
            }
            pendingFavorite = null
        }

    val current = queue.getOrNull(index)

    fun act(delete: Boolean) {
        val photo = queue.getOrNull(index) ?: return
        if (delete) store.markTrash(photo) else store.keep(photo)
        index++
    }

    Column(modifier = Modifier.fillMaxSize()) {
        TopBar(title = store.month(monthKey)?.title ?: "SwipeClean", onBack = onBack) {
            if (current != null) {
                Text(
                    text = "${queue.size - index} left",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(end = 12.dp),
                )
            }
        }

        if (current != null) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                key(current.id) {
                    SwipeCard(photo = current, onSwipe = { act(it) })
                }
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FilledTonalIconButton(onClick = { act(true) }, modifier = Modifier.size(56.dp)) {
                    Icon(Icons.Filled.Delete, contentDescription = "Delete", tint = Color(0xFFD32F2F))
                }
                FilledTonalIconButton(
                    onClick = {
                        if (index > undoFloor) {
                            index--
                            store.unreview(queue[index])
                        }
                    },
                    enabled = index > undoFloor,
                    modifier = Modifier.size(56.dp),
                ) {
                    Text("↩", fontSize = 22.sp)
                }
                val favorite = store.isFavorite(current)
                FilledTonalIconButton(
                    onClick = {
                        val newValue = !favorite
                        pendingFavorite = current.id to newValue
                        val request = MediaStore.createFavoriteRequest(
                            context.contentResolver, listOf(current.uri), newValue
                        )
                        favoriteLauncher.launch(IntentSenderRequest.Builder(request.intentSender).build())
                    },
                    modifier = Modifier.size(56.dp),
                ) {
                    Icon(
                        if (favorite) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder,
                        contentDescription = "Favourite",
                        tint = Color(0xFFE91E63),
                    )
                }
                FilledTonalIconButton(
                    onClick = {
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "image/*"
                            putExtra(Intent.EXTRA_STREAM, current.uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        context.startActivity(Intent.createChooser(send, null))
                    },
                    modifier = Modifier.size(56.dp),
                ) {
                    Icon(Icons.Filled.Share, contentDescription = "Share")
                }
                FilledTonalIconButton(onClick = { act(false) }, modifier = Modifier.size(56.dp)) {
                    Icon(Icons.Filled.Check, contentDescription = "Keep", tint = Color(0xFF2E7D32))
                }
            }
        } else {
            Column(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(24.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(
                    Icons.Filled.CheckCircle,
                    contentDescription = null,
                    tint = Color(0xFF2E7D32),
                    modifier = Modifier.size(72.dp),
                )
                Spacer(Modifier.height(12.dp))
                Text("Month done", style = MaterialTheme.typography.headlineSmall)
                if (store.trash.isNotEmpty()) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Photos you marked are removed once you confirm below.",
                        textAlign = TextAlign.Center,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.height(16.dp))
                Button(onClick = onBack) { Text("Back to months") }
                if (store.month(monthKey) != null) {
                    TextButton(onClick = {
                        store.resetMonth(monthKey)
                        queue = store.unreviewed(monthKey)
                        index = 0
                        undoFloor = 0
                    }) { Text("Review this month again") }
                }
            }
        }

        TrashBar(store.trash.size, onShowTrash)
    }
}

private val cardDate: DateTimeFormatter = DateTimeFormatter.ofPattern("d MMM yyyy")

@Composable
fun SwipeCard(photo: Photo, onSwipe: (Boolean) -> Unit) {
    val offsetX = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    val currentOnSwipe by rememberUpdatedState(onSwipe)
    var thresholdPx by remember { mutableStateOf(1f) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .graphicsLayer {
                translationX = offsetX.value
                rotationZ = offsetX.value / 45f
            }
            .clip(RoundedCornerShape(22.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .pointerInput(Unit) {
                val threshold = 110.dp.toPx()
                thresholdPx = threshold
                val width = size.width.toFloat()
                detectDragGestures(
                    onDragEnd = {
                        scope.launch {
                            val x = offsetX.value
                            if (abs(x) > threshold) {
                                offsetX.animateTo(if (x < 0) -width * 1.5f else width * 1.5f, tween(180))
                                currentOnSwipe(x < 0)
                            } else {
                                offsetX.animateTo(0f)
                            }
                        }
                    },
                    onDragCancel = { scope.launch { offsetX.animateTo(0f) } },
                    onDrag = { change, dragAmount ->
                        change.consume()
                        scope.launch { offsetX.snapTo(offsetX.value + dragAmount.x) }
                    },
                )
            },
    ) {
        AsyncImage(
            model = photo.uri,
            contentDescription = null,
            contentScale = ContentScale.Fit,
            modifier = Modifier.fillMaxSize(),
        )
        Badge(
            text = "KEEP",
            color = Color(0xFF2E7D32),
            modifier = Modifier
                .align(Alignment.TopStart)
                .graphicsLayer { alpha = (offsetX.value / thresholdPx).coerceIn(0f, 1f) },
        )
        Badge(
            text = "DELETE",
            color = Color(0xFFD32F2F),
            modifier = Modifier
                .align(Alignment.TopEnd)
                .graphicsLayer { alpha = (-offsetX.value / thresholdPx).coerceIn(0f, 1f) },
        )
        Text(
            text = Instant.ofEpochMilli(photo.dateMs).atZone(ZoneId.systemDefault()).format(cardDate),
            color = Color.White,
            style = MaterialTheme.typography.labelMedium,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(10.dp)
                .background(Color(0x99000000), RoundedCornerShape(50))
                .padding(horizontal = 10.dp, vertical = 4.dp),
        )
    }
}

@Composable
fun Badge(text: String, color: Color, modifier: Modifier = Modifier) {
    Text(
        text = text,
        color = color,
        fontWeight = FontWeight.Black,
        fontSize = 20.sp,
        modifier = modifier
            .padding(18.dp)
            .border(3.dp, color, RoundedCornerShape(8.dp))
            .padding(horizontal = 12.dp, vertical = 6.dp),
    )
}

// ---------------------------------------------------------------- Trash review

@Composable
fun TrashScreen(store: PhotoStore, onBack: () -> Unit, onDelete: () -> Unit) {
    BackHandler(onBack = onBack)
    Column(modifier = Modifier.fillMaxSize()) {
        TopBar(title = "${store.trash.size} to delete", onBack = onBack) {
            TextButton(onClick = onDelete, enabled = store.trash.isNotEmpty()) {
                Text("Delete all", color = Color(0xFFD32F2F))
            }
        }
        Text(
            text = "Tap a photo to keep it instead.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 6.dp),
        )
        LazyVerticalGrid(
            columns = GridCells.Adaptive(100.dp),
            modifier = Modifier.weight(1f),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            items(store.trash, key = { it.id }) { photo ->
                AsyncImage(
                    model = photo.uri,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .aspectRatio(1f)
                        .clickable { store.restore(photo) },
                )
            }
        }
    }
}
