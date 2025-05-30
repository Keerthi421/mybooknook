import 'package:flutter/material.dart';
import '../models/book.dart';
import '../services/book_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/settings.dart' as app_settings;
import 'dart:convert';
import 'package:share_plus/share_plus.dart';
import 'package:http/http.dart' as http;
import 'scan_book_details_card.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'author_details_card.dart';

class BookDetailsCard extends StatefulWidget {
  final Book book;
  final String listName;
  final BookService bookService;
  final String? listId;
  final Function(String)? onAddToList;
  final Map<String, String>? lists;
  final String? actualListId;

  const BookDetailsCard({
    super.key,
    required this.book,
    required this.listName,
    required this.bookService,
    this.listId,
    this.onAddToList,
    this.lists,
    this.actualListId,
  });

  static void show(BuildContext context, Book book, String listName,
      BookService bookService, String? listId,
      {String? actualListId}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return BookDetailsCard(
          book: book,
          listName: listName,
          bookService: bookService,
          listId: listId,
          actualListId: actualListId,
        );
      },
    );
  }

  @override
  State<BookDetailsCard> createState() => _BookDetailsCardState();
}

class _BookDetailsCardState extends State<BookDetailsCard> {
  final ScrollController scrollController = ScrollController();
  bool _isExpanded = false;
  double _userRating = 0;
  bool _isDescriptionExpanded = false;
  ScrollController? _scrollController;
  bool _canDismiss = false;
  bool _isRead = false;
  bool _isFavorite = false;

  @override
  void initState() {
    super.initState();
    _userRating = widget.book.userRating ?? 0;
    _scrollController = ScrollController();
    _scrollController?.addListener(_handleScroll);
    _loadReadingStatus();
    _loadFavoriteStatus();
  }

  @override
  void dispose() {
    scrollController.removeListener(_onScroll);
    scrollController.dispose();
    _scrollController?.removeListener(_handleScroll);
    _scrollController?.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (scrollController.position.pixels <= 0) {
      // Allow dismissal when at the top
      Navigator.of(context).pop();
    }
  }

  void _handleScroll() {
    if (_scrollController?.position.pixels == 0) {
      setState(() {
        _canDismiss = true;
      });
    } else if (_canDismiss) {
      setState(() {
        _canDismiss = false;
      });
    }
  }

  Future<void> _updateReadingStatus(BuildContext context, bool isRead) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final completedBooksKey = 'completed_books';
      final completedBooks = prefs.getStringList(completedBooksKey) ?? [];

      if (isRead) {
        if (!completedBooks.contains(widget.book.isbn)) {
          completedBooks.add(widget.book.isbn);
          await prefs.setStringList(completedBooksKey, completedBooks);

          // Update reading statistics
          final settings = app_settings.Settings();
          await settings.load();
          await settings.incrementReadBooks();
          await settings.save();
        }
      } else {
        if (completedBooks.contains(widget.book.isbn)) {
          completedBooks.remove(widget.book.isbn);
          await prefs.setStringList(completedBooksKey, completedBooks);

          // Update reading statistics
          final settings = app_settings.Settings();
          await settings.load();
          await settings.decrementReadBooks();
          await settings.save();
        }
      }

      // Update the state immediately
      if (mounted) {
        setState(() {
          widget.book.isRead = isRead;
        });
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reading status updated')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating status: $e')),
        );
      }
    }
  }

  Future<void> _updateUserRating(BuildContext context, double rating) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final bookRef = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('lists')
          .doc(widget.listId)
          .collection('books')
          .doc(widget.book.isbn);

      await bookRef.update({
        'userRating': rating,
      });

      setState(() {
        _userRating = rating;
      });

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Rating updated')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating rating: $e')),
        );
      }
    }
  }

  Future<void> _loadReadingStatus() async {
    final isCompleted = await Book.isBookCompleted(widget.book.isbn);
    if (mounted) {
      setState(() {
        widget.book.isRead = isCompleted;
      });
    }
  }

  Future<void> _loadFavoriteStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final favoriteBooksJson = prefs.getString('favoriteBooks') ?? '[]';
    final List<dynamic> favoriteBooksList = jsonDecode(favoriteBooksJson);
    final isFavorite =
        favoriteBooksList.any((book) => book['isbn'] == widget.book.isbn);
    if (mounted) {
      setState(() {
        _isFavorite = isFavorite;
      });
    }
  }

  Future<void> _toggleFavorite() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      // Update Firebase
      final bookRef = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('books')
          .doc(widget.book.isbn);

      if (_isFavorite) {
        // Remove from favorites in Firebase
        await bookRef.update({
          'isFavorite': false,
        });
      } else {
        // Add to favorites in Firebase
        await bookRef.set({
          ...widget.book.toMap(),
          'isFavorite': true,
          'listId': widget.listId,
        }, SetOptions(merge: true));
      }

      // Update SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final favoriteBooksJson = prefs.getString('favoriteBooks') ?? '[]';
      final List<dynamic> favoriteBooksList = jsonDecode(favoriteBooksJson);

      if (_isFavorite) {
        // Remove from favorites
        favoriteBooksList
            .removeWhere((book) => book['isbn'] == widget.book.isbn);
      } else {
        // Add to favorites
        favoriteBooksList.add({
          'title': widget.book.title,
          'authors': widget.book.authors,
          'imageUrl': widget.book.imageUrl,
          'isbn': widget.book.isbn,
          'listId': widget.listId,
        });
      }

      await prefs.setString('favoriteBooks', jsonEncode(favoriteBooksList));

      if (mounted) {
        setState(() {
          _isFavorite = !_isFavorite;
        });
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                _isFavorite ? 'Removed from favorites' : 'Added to favorites'),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating favorite status: $e')),
        );
      }
    }
  }

  Future<void> _shareBook() async {
    try {
      // Create a URL with just the ISBN
      final longUrl =
          'https://mybooknook-5ca64.web.app/book?isbn=${widget.book.isbn}';

      // Use is.gd to create a short URL
      final response = await http.get(
        Uri.parse(
            'https://is.gd/create.php?format=json&url=${Uri.encodeComponent(longUrl)}'),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final shortUrl = data['shorturl'];

        if (shortUrl != null) {
          await Share.share(
            'Check out ${widget.book.title} on MyBookNook!\n$shortUrl',
          );
        } else {
          throw Exception('Failed to get short URL');
        }
      } else {
        throw Exception('Failed to create short URL');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error sharing book: $e')),
        );
      }
    }
  }

  Future<void> _showFriendSelection() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      // Get all friends first to debug the structure
      final friendsSnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('friends')
          .get();

      // Debug print to check the friends data
      print('Found ${friendsSnapshot.docs.length} total friends');
      for (var doc in friendsSnapshot.docs) {
        print('Friend document ID: ${doc.id}');
        print('Friend data: ${doc.data()}');
        print('Friend data keys: ${doc.data().keys.toList()}');
      }

      if (!mounted) return;

      if (friendsSnapshot.docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You don\'t have any friends yet'),
          ),
        );
        return;
      }

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (BuildContext context) {
          return DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.5,
            maxChildSize: 0.95,
            expand: false,
            builder: (context, scrollController) {
              return Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Center(
                            child: Container(
                              width: 40,
                              height: 4,
                              margin: const EdgeInsets.only(bottom: 16),
                              decoration: BoxDecoration(
                                color: Theme.of(context).dividerColor,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          Text(
                            'Send to Friend',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Select a friend to share "${widget.book.title}" with',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: scrollController,
                        itemCount: friendsSnapshot.docs.length,
                        itemBuilder: (context, index) {
                          final friend = friendsSnapshot.docs[index];
                          final friendData = friend.data();
                          print('Building list item for friend: $friendData');

                          return ListTile(
                            leading: CircleAvatar(
                              child: Text(
                                friendData['username']?[0]?.toUpperCase() ??
                                    '?',
                              ),
                            ),
                            title:
                                Text('@${friendData['username'] ?? 'Unknown'}'),
                            trailing: IconButton(
                              icon: const Icon(Icons.send),
                              onPressed: () async {
                                try {
                                  // Get current user's username
                                  final currentUserDoc = await FirebaseFirestore
                                      .instance
                                      .collection('users')
                                      .doc(user.uid)
                                      .get();
                                  final currentUsername =
                                      currentUserDoc.data()?['username'] ??
                                          'Unknown User';

                                  // Create notification data
                                  final notificationData = {
                                    'type': 'book_share',
                                    'title': 'Book Shared',
                                    'message':
                                        '@$currentUsername shared "${widget.book.title}" with you',
                                    'timestamp': FieldValue.serverTimestamp(),
                                    'isRead': false,
                                    'fromUserId': user.uid,
                                    'fromUsername': currentUsername,
                                    'toUserId': friend.id,
                                    'bookTitle': widget.book.title,
                                    'bookIsbn': widget.book.isbn,
                                    'action': 'scan_book',
                                    'actionData': {
                                      'isbn': widget.book.isbn,
                                    },
                                  };

                                  // Use a batch write
                                  final batch =
                                      FirebaseFirestore.instance.batch();

                                  // Add the notification
                                  final notificationRef = FirebaseFirestore
                                      .instance
                                      .collection('users')
                                      .doc(friend.id)
                                      .collection('notifications')
                                      .doc();

                                  batch.set(notificationRef, notificationData);

                                  // Commit the batch
                                  await batch.commit();

                                  if (context.mounted) {
                                    Navigator.pop(context);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'Book shared with @${friendData['username']}',
                                        ),
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  print('Error sharing book: $e');
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Error sharing book: $e'),
                                      ),
                                    );
                                  }
                                }
                              },
                            ),
                            onTap: null, // Disable the entire row tap
                          );
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    } catch (e) {
      print('Error in _showFriendSelection: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading friends: $e')),
        );
      }
    }
  }

  Future<void> _launchUrl(String urlString) async {
    final Uri url = Uri.parse(urlString);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not launch URL')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      snap: true,
      snapSizes: const [0.5, 0.7, 0.9, 0.95],
      builder: (context, scrollController) => WillPopScope(
        onWillPop: () async {
          if (_scrollController?.position.pixels != 0) {
            _scrollController?.animateTo(
              0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
            return false;
          }
          return true;
        },
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).dividerColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  controller: _scrollController,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.book.imageUrl != null)
                              Image.network(
                                widget.book.imageUrl!,
                                width: 120,
                                height: 180,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) =>
                                    const Icon(Icons.book, size: 120),
                              )
                            else
                              const Icon(Icons.book, size: 120),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          widget.book.title,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleLarge,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (widget.book.authors != null &&
                                      widget.book.authors!.isNotEmpty)
                                    GestureDetector(
                                      onTap: () {
                                        showModalBottomSheet(
                                          context: context,
                                          isScrollControlled: true,
                                          builder: (BuildContext context) {
                                            return AuthorDetailsCard(
                                              authorName:
                                                  widget.book.authors!.first,
                                            );
                                          },
                                        );
                                      },
                                      child: Text(
                                        widget.book.authors!.join(', '),
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                            ),
                                      ),
                                    ),
                                  if (widget.book.publisher != null)
                                    Text(
                                      'Published by ${widget.book.publisher}',
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                    ),
                                  if (widget.book.publishedDate != null)
                                    Text(
                                      'Published: ${widget.book.publishedDate}',
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                    ),
                                  if (widget.book.pageCount != null)
                                    Text(
                                      '${widget.book.pageCount} pages',
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        if (widget.book.description != null) ...[
                          Text(
                            'Description',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.book.description!,
                                maxLines: _isDescriptionExpanded ? null : 5,
                                overflow: _isDescriptionExpanded
                                    ? null
                                    : TextOverflow.ellipsis,
                              ),
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    _isDescriptionExpanded =
                                        !_isDescriptionExpanded;
                                  });
                                },
                                child: Text(_isDescriptionExpanded
                                    ? 'Show Less'
                                    : 'Show More'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        Text(
                          'Your Rating',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            ...List.generate(5, (index) {
                              return IconButton(
                                icon: Icon(
                                  index < _userRating
                                      ? Icons.star
                                      : Icons.star_border,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                onPressed: () {
                                  _updateUserRating(context, index + 1.0);
                                },
                              );
                            }),
                            const SizedBox(width: 8),
                            Text('${_userRating.toInt()}/5'),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Reading Status',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          title: const Text('Mark as read'),
                          value: widget.book.isRead,
                          onChanged: (value) {
                            if (value != null) {
                              _updateReadingStatus(context, value);
                            }
                          },
                        ),
                        ListTile(
                          title: const Text('Mark as favorite'),
                          trailing: IconButton(
                            icon: Icon(
                              _isFavorite ? Icons.star : Icons.star_border,
                              color: _isFavorite ? Colors.amber : null,
                            ),
                            onPressed: _toggleFavorite,
                          ),
                          onTap: _toggleFavorite,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Sharing',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: _shareBook,
                                  icon: const Icon(Icons.share),
                                  label: const Text('Share Link'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Theme.of(context)
                                        .colorScheme
                                        .primaryContainer,
                                    foregroundColor: Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: _showFriendSelection,
                                  icon: const Icon(Icons.person_add),
                                  label: const Text('Send to friend'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Theme.of(context)
                                        .colorScheme
                                        .primaryContainer,
                                    foregroundColor: Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Purchase Book',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 15),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                children: [
                                  SizedBox(
                                    width: 98,
                                    height: 48,
                                    child: ElevatedButton(
                                      onPressed: () {
                                        final url =
                                            'https://books.google.com/books?isbn=${widget.book.isbn}';
                                        _launchUrl(url);
                                      },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Theme.of(context)
                                            .colorScheme
                                            .primaryContainer,
                                        padding: EdgeInsets.zero,
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                      ),
                                      child: SvgPicture.asset(
                                        'assets/logos/google_books.svg',
                                        height: 24,
                                        width: 24,
                                        fit: BoxFit.contain,
                                        placeholderBuilder: (context) =>
                                            const Icon(Icons.book, size: 24),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      'Google Books',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                children: [
                                  SizedBox(
                                    width: 98,
                                    height: 48,
                                    child: ElevatedButton(
                                      onPressed: () {
                                        final url =
                                            'https://www.amazon.com/s?k=${widget.book.isbn}';
                                        _launchUrl(url);
                                      },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Theme.of(context)
                                            .colorScheme
                                            .primaryContainer,
                                        padding: EdgeInsets.zero,
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.only(top: 5),
                                        child: SvgPicture.asset(
                                          'assets/logos/amazon.svg',
                                          height: 19.2,
                                          width: 19.2,
                                          fit: BoxFit.contain,
                                          placeholderBuilder: (context) =>
                                              const Icon(Icons.shopping_cart,
                                                  size: 19.2),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      'Amazon',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                children: [
                                  SizedBox(
                                    width: 98,
                                    height: 48,
                                    child: ElevatedButton(
                                      onPressed: () {
                                        final url =
                                            'https://www.abebooks.com/servlet/SearchResults?isbn=${widget.book.isbn}';
                                        _launchUrl(url);
                                      },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Theme.of(context)
                                            .colorScheme
                                            .primaryContainer,
                                        padding: EdgeInsets.zero,
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                      ),
                                      child: SvgPicture.asset(
                                        'assets/logos/abebooks.svg',
                                        height: 24,
                                        width: 24,
                                        fit: BoxFit.contain,
                                        placeholderBuilder: (context) =>
                                            const Icon(Icons.store, size: 24),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      'AbeBooks',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 15),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Divider(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                        const SizedBox(height: 15),
                        SizedBox(
                          width: double.infinity,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(5, 0, 5, 10),
                            child: ElevatedButton(
                              onPressed: () async {
                                final shouldDelete = await showDialog<bool>(
                                  context: context,
                                  builder: (BuildContext context) {
                                    return AlertDialog(
                                      title: const Text('Delete Book'),
                                      content: Text(
                                        'Are you sure you want to delete "${widget.book.title}" from ${widget.listName}?',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('Cancel'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: const Text(
                                            'Delete',
                                            style: TextStyle(color: Colors.red),
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                );

                                if (shouldDelete == true) {
                                  try {
                                    final user =
                                        FirebaseAuth.instance.currentUser;
                                    if (user == null) return;

                                    // Get the book's actual list ID from the document path
                                    final bookRef = FirebaseFirestore.instance
                                        .collection('users')
                                        .doc(user.uid)
                                        .collection('lists')
                                        .doc(widget.actualListId ??
                                            widget.listId)
                                        .collection('books')
                                        .doc(widget.book.isbn);

                                    await bookRef.delete();

                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Book deleted from ${widget.listName}',
                                          ),
                                        ),
                                      );
                                      Navigator.pop(context);
                                    }
                                  } catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content:
                                              Text('Error deleting book: $e'),
                                        ),
                                      );
                                    }
                                  }
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: const Text(
                                'Delete Book',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],

          ),
        ),
      ),
    );
  }
}
