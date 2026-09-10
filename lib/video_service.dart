Future<String?> generateVideoFromImage(String imageUrl, String prompt, String apiKey) async {
  // Luma Dream Machine ya similar API endpoint
  final url = Uri.parse('https://api.lumalabs.ai/dream-machine/v1/generations');
  final response = await http.post(
    url,
    headers: {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'prompt': prompt,
      'keyframes': {
        'frame0': {'type': 'image', 'url': imageUrl}
      }
    }),
  );
  
  if (response.statusCode == 201) {
    final data = jsonDecode(response.body);
    return data['id']; // Generation check karne ke liye task ID
  }
  return null;
}
