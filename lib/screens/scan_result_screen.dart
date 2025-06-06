import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:logging/logging.dart';
import 'package:file_picker/file_picker.dart';
import '/l10n/app_localizations.dart';

class ResultScreen extends StatefulWidget {
  const ResultScreen({super.key, required this.code, required this.type});

  final String code;
  final BarcodeType type;

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  bool _isWifiPasswordVisible = false;
  Uri? _launchableUri;
  final _log = Logger('ScannerResultsScreenState');
  Map<String, String?> _parsedUriParams = {};
  Map<String, List<String>> _parsedVCard = {};
  Map<String, String>? _wifiCredentials;

  @override
  void initState() {
    super.initState();
    _parseDataBasedOnType();
  }

  void _parseDataBasedOnType() {
    _launchableUri = null;
    _wifiCredentials = null;
    _parsedUriParams = {};
    _parsedVCard = {};

    switch (widget.type) {
      case BarcodeType.url:
      case BarcodeType.phone:
        _launchableUri = Uri.tryParse(widget.code);
        break;

      case BarcodeType.sms:
        _launchableUri = Uri.tryParse(widget.code);
        if (_launchableUri != null) {
          String? smsNumber;
          String? smsBody;

          if (_launchableUri!.scheme == 'sms') {
            smsNumber = _launchableUri!.path;
            smsBody = _launchableUri!.queryParameters['body'];
          } else if (_launchableUri!.scheme == 'smsto') {
            final pathParts = _launchableUri!.path.split(':');
            if (pathParts.isNotEmpty) {
              smsNumber = pathParts[0];
            }
            if (pathParts.length > 1) {
              smsBody = Uri.decodeComponent(pathParts.sublist(1).join(':'));
            }
          }

          if (smsNumber != null && smsNumber.isNotEmpty) {
            _parsedUriParams['to'] = smsNumber;
          }
          if (smsBody != null && smsBody.isNotEmpty) {
            _parsedUriParams['body'] = smsBody;
          }
        }
        break;

      case BarcodeType.email:
        if (widget.code.toLowerCase().startsWith('mailto:')) {
          _launchableUri = Uri.tryParse(widget.code);
          if (_launchableUri != null) {
            _parsedUriParams['to'] = _launchableUri!.path;
            _parsedUriParams.addAll(_launchableUri!.queryParameters);
          }
        } else if (widget.code.contains('@')) {
          _launchableUri = Uri.tryParse('mailto:${widget.code}');
          _parsedUriParams['to'] = widget.code;
        }
        break;

      case BarcodeType.geo:
        _launchableUri = Uri.tryParse(widget.code);
        if (_launchableUri?.scheme != 'geo') {
          if (RegExp(r'^-?\d+(\.\d+)?,-?\d+(\.\d+)?$').hasMatch(widget.code)) {
            _launchableUri = Uri.tryParse('geo:${widget.code}');
          } else {
            _launchableUri = null;
          }
        }

        if (_launchableUri != null) {
          _parsedUriParams = _launchableUri!.queryParameters;
          final path = _launchableUri!.path;
          final parts = path.split(',');
          if (parts.length >= 2) {
            _parsedUriParams['lat'] = parts[0];
            _parsedUriParams['lon'] = parts[1];
            if (parts.length > 2) {
              _parsedUriParams['alt'] = parts[2];
            }
          }
        }
        break;

      case BarcodeType.wifi:
        _parseWifiCode(widget.code);
        break;

      case BarcodeType.contactInfo:
        _parsedVCard = _parseVCardSimple(widget.code);
        break;

      default:
        break;
    }
  }

  void _parseWifiCode(String code) {
    if (code.startsWith('WIFI:')) {
      final Map<String, String> credentials = {};
      final String data = code.substring(5);
      final List<String> parts = data.split(RegExp(r'(?<!\\);'));

      for (String part in parts) {
        if (part.isNotEmpty) {
          final separatorIndex = part.indexOf(RegExp(r'(?<!\\):'));
          if (separatorIndex != -1) {
            final key = part.substring(0, separatorIndex);
            String value = part.substring(separatorIndex + 1);
            value = value
                .replaceAll('\\\\', '\\')
                .replaceAll('\\;', ';')
                .replaceAll('\\:', ':')
                .replaceAll('\\"', '"')
                .replaceAll('\\,', ',');
            credentials[key] = value;
          }
        }
      }

      if (credentials.isNotEmpty) {
        final lastKey = credentials.keys.last;
        if (credentials[lastKey]!.endsWith(';')) {
          credentials[lastKey] = credentials[lastKey]!.substring(
            0,
            credentials[lastKey]!.length - 1,
          );
        }
      }

      if (credentials.containsKey('S')) {
        _wifiCredentials = credentials;
        _wifiCredentials!.putIfAbsent('T', () => 'nopass');
        _wifiCredentials!.putIfAbsent('P', () => '');
      }
    }
  }

  Map<String, List<String>> _parseVCardSimple(String vCardString) {
    final Map<String, List<String>> data = {};
    final lines = vCardString.split('\n');

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty ||
          line.toUpperCase().startsWith('BEGIN:') ||
          line.toUpperCase().startsWith('END:')) {
        continue;
      }

      final colonIndex = line.indexOf(':');
      if (colonIndex == -1) continue;

      final keyPart = line.substring(0, colonIndex);
      final value = line.substring(colonIndex + 1).trim();

      final key = keyPart.split(';').first.toUpperCase();

      const knownKeys = {
        'FN',
        'N',
        'ORG',
        'TITLE',
        'TEL',
        'EMAIL',
        'ADR',
        'URL',
        'NOTE',
      };
      if (knownKeys.contains(key)) {
        data.update(key, (list) => list..add(value), ifAbsent: () => [value]);
      }
    }
    return data;
  }

  Future<void> _launchUriAction(Uri uri) async {
    final l10n = AppLocalizations.of(context);

    try {
      final mode =
          (uri.scheme == 'http' || uri.scheme == 'https')
              ? LaunchMode.externalApplication
              : LaunchMode.platformDefault;

      bool launched = await launchUrl(uri, mode: mode);
      if (!launched && mounted) {
        _showSnackBar(l10n.couldNotPerformActionText(uri.toString()));
      }
    } catch (e) {
      _log.severe("Error launching URL: $e");
      if (mounted) {
        _showSnackBar(l10n.urlLaunchError(e.toString()));
      }
    }
  }

  void _copyToClipboard(String text, String confirmationMessage) {
    Clipboard.setData(ClipboardData(text: text));
    _showSnackBar(confirmationMessage);
  }

  void _copyWifiCredentials() {
    final l10n = AppLocalizations.of(context);
    if (_wifiCredentials == null) return;

    final ssid = _wifiCredentials!['S'] ?? 'N/A';
    final password = _wifiCredentials!['P'] ?? l10n.noPasswordLabel;
    final type = _wifiCredentials!['T'] ?? 'N/A';

    final String ssidText = l10n.ssidLabel;
    final String passwordText = l10n.passwordLabel;
    final String typeText = l10n.typeLabel;
    final String wifiText = l10n.wifiNetworkLabel;

    final String credentialsText =
        '$wifiText\n$ssidText $ssid\n$passwordText $password\n$typeText $type';

    _copyToClipboard(credentialsText, l10n.wifiCredentialsCopied);
  }

  Future<void> _exportVCard() async {
    final l10n = AppLocalizations.of(context);
    if (widget.type != BarcodeType.contactInfo || widget.code.isEmpty) {
      _showSnackBar(l10n.noVCardData);
      return;
    }

    try {
      final textBytes = utf8.encode(widget.code);
      final fileBytes = Uint8List.fromList(textBytes);

      String suggestedFileName = 'contact.vcf';
      if (_parsedVCard.containsKey('FN') && _parsedVCard['FN']!.isNotEmpty) {
        suggestedFileName =
            '${_parsedVCard['FN']!.first.replaceAll(RegExp(r'[^\w\s]+'), '_')}.vcf';
      } else if (_parsedVCard.containsKey('N') &&
          _parsedVCard['N']!.isNotEmpty) {
        final nameParts = _parsedVCard['N']!.first.split(';');
        final firstName = nameParts.length > 1 ? nameParts[1] : '';
        final lastName = nameParts.isNotEmpty ? nameParts[0] : '';
        if (firstName.isNotEmpty || lastName.isNotEmpty) {
          suggestedFileName =
              '${'${firstName}_$lastName'.replaceAll(RegExp(r'[^\w\s]+'), '_').replaceAll('__', '_').trim()}.vcf';
        }
      } else {
        suggestedFileName =
            'contact_${DateTime.now().millisecondsSinceEpoch}.vcf';
      }

      String? outputFile = await FilePicker.platform.saveFile(
        dialogTitle: l10n.saveContactDialogTitle,
        fileName: suggestedFileName,
        allowedExtensions: ['vcf'],
        type: FileType.custom,
        bytes: fileBytes,
      );

      if (outputFile != null) {
        _showSnackBar(l10n.vCardSaved);
        _log.info("vCard saved as a file");
      } else {
        _showSnackBar(l10n.vCardExportCancelled);
      }
    } catch (e) {
      _log.severe("Error saving vCard: $e");
      if (mounted) {
        _showSnackBar(l10n.vCardExportError(e.toString()));
      }
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  Widget _buildVCardContent(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    List<Widget> vCardRows = [];

    String displayName = "N/A";
    if (_parsedVCard['FN']?.isNotEmpty ?? false) {
      displayName = _parsedVCard['FN']!.first;
      vCardRows.add(
        _buildInfoRow(
          context,
          Icons.person_outline,
          l10n.nameLabel,
          displayName,
        ),
      );
    } else if (_parsedVCard['N']?.isNotEmpty ?? false) {
      final nameParts = _parsedVCard['N']!.first.split(';');
      final firstName = nameParts.length > 1 ? nameParts[1] : '';
      final lastName = nameParts.isNotEmpty ? nameParts[0] : '';
      displayName = '$firstName $lastName'.trim();
      if (displayName.isNotEmpty) {
        vCardRows.add(
          _buildInfoRow(
            context,
            Icons.person_outline,
            l10n.nameLabel,
            displayName,
          ),
        );
      }
    }

    if (_parsedVCard['ORG']?.isNotEmpty ?? false) {
      vCardRows.add(
        _buildInfoRow(
          context,
          Icons.business,
          l10n.organizationLabel,
          _parsedVCard['ORG']!.first,
        ),
      );
    }
    if (_parsedVCard['TITLE']?.isNotEmpty ?? false) {
      vCardRows.add(
        _buildInfoRow(
          context,
          Icons.work_outline,
          l10n.titleLabel,
          _parsedVCard['TITLE']!.first,
        ),
      );
    }

    if (_parsedVCard['TEL']?.isNotEmpty ?? false) {
      for (final phone in _parsedVCard['TEL']!) {
        vCardRows.add(
          _buildInfoRow(context, Icons.phone_outlined, l10n.phoneLabel, phone),
        );
      }
    }

    if (_parsedVCard['EMAIL']?.isNotEmpty ?? false) {
      for (final email in _parsedVCard['EMAIL']!) {
        vCardRows.add(
          _buildInfoRow(context, Icons.email_outlined, l10n.emailLabel, email),
        );
      }
    }

    if (_parsedVCard['ADR']?.isNotEmpty ?? false) {
      for (final adr in _parsedVCard['ADR']!) {
        final adrParts = adr.split(';');
        final displayAdr = [
          if (adrParts.length > 2 && adrParts[2].isNotEmpty)
            adrParts[2], // Street
          if (adrParts.length > 3 && adrParts[3].isNotEmpty)
            adrParts[3], // City
          if (adrParts.length > 4 && adrParts[4].isNotEmpty)
            adrParts[4], // Region
          if (adrParts.length > 5 && adrParts[5].isNotEmpty)
            adrParts[5], // Postal Code
          if (adrParts.length > 6 && adrParts[6].isNotEmpty)
            adrParts[6], // Country
        ].where((part) => part.isNotEmpty).join(', ');

        if (displayAdr.isNotEmpty) {
          vCardRows.add(
            _buildInfoRow(
              context,
              Icons.location_on_outlined,
              l10n.addressLabel,
              displayAdr,
            ),
          );
        }
      }
    }

    if (_parsedVCard['URL']?.isNotEmpty ?? false) {
      for (final url in _parsedVCard['URL']!) {
        vCardRows.add(
          _buildInfoRow(context, Icons.link, l10n.websiteLabel, url),
        );
      }
    }

    if (_parsedVCard['NOTE']?.isNotEmpty ?? false) {
      vCardRows.add(
        _buildInfoRow(
          context,
          Icons.note_outlined,
          l10n.noteLabel,
          _parsedVCard['NOTE']!.first,
        ),
      );
    }

    if (vCardRows.isEmpty) {
      return _buildRawContentWithLabel(context, l10n.contactInfoLabel);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: vCardRows,
    );
  }

  Widget _buildFormattedContent(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final textStyle = theme.textTheme.bodyLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final labelStyle = textStyle?.copyWith(fontWeight: FontWeight.bold);

    switch (widget.type) {
      case BarcodeType.wifi:
        if (_wifiCredentials != null) {
          final String password = _wifiCredentials!['P'] ?? '';
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoRow(
                context,
                Icons.wifi,
                l10n.ssidLabel,
                _wifiCredentials!['S'] ?? 'N/A',
              ),
              _buildInfoRow(
                context,
                Icons.lock_outline,
                l10n.typeLabel,
                _wifiCredentials!['T'] ?? 'N/A',
              ),
              Row(
                children: [
                  Icon(
                    Icons.password,
                    color: labelStyle?.color?.withAlpha(140),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(l10n.passwordLabel, style: labelStyle),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SelectableText(
                      password.isEmpty
                          ? l10n.noneLabel
                          : _isWifiPasswordVisible
                          ? password
                          : ('*' * password.length),
                      style: textStyle?.copyWith(
                        fontStyle:
                            password.isEmpty
                                ? FontStyle.italic
                                : FontStyle.normal,
                      ),
                    ),
                  ),
                  if (password.isNotEmpty)
                    IconButton(
                      icon: Icon(
                        _isWifiPasswordVisible
                            ? Icons.visibility_off
                            : Icons.visibility,
                        color: theme.colorScheme.primary,
                      ),
                      tooltip:
                          _isWifiPasswordVisible
                              ? l10n.hidePasswordTooltip
                              : l10n.showPasswordTooltip,
                      onPressed:
                          password.isNotEmpty
                              ? () {
                                setState(() {
                                  _isWifiPasswordVisible =
                                      !_isWifiPasswordVisible;
                                });
                              }
                              : null,
                    )
                  else
                    const SizedBox(width: 48),
                ],
              ),
              if (_wifiCredentials!['H'] == 'true')
                _buildInfoRow(
                  context,
                  Icons.visibility_off_outlined,
                  l10n.hiddenLabel,
                  l10n.yesLabel,
                ),
            ],
          );
        }
        break;

      case BarcodeType.email:
        if (_parsedUriParams['to'] != null ||
            _launchableUri?.path.isNotEmpty == true) {
          final recipient =
              _parsedUriParams['to'] ?? _launchableUri?.path ?? 'N/A';
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoRow(
                context,
                Icons.alternate_email,
                l10n.toLabel,
                recipient,
              ),
              if (_parsedUriParams['subject'] != null)
                _buildInfoRow(
                  context,
                  Icons.subject,
                  l10n.subjectLabel,
                  _parsedUriParams['subject']!,
                ),
              if (_parsedUriParams['body'] != null)
                _buildInfoRow(
                  context,
                  Icons.article_outlined,
                  l10n.bodyLabel,
                  _parsedUriParams['body']!,
                ),
            ],
          );
        }
        break;

      case BarcodeType.sms:
        if (_parsedUriParams['to'] != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoRow(
                context,
                Icons.phone_android,
                l10n.toLabel,
                _parsedUriParams['to']!,
              ),
              if (_parsedUriParams['body'] != null)
                _buildInfoRow(
                  context,
                  Icons.article_outlined,
                  l10n.bodyLabel,
                  _parsedUriParams['body']!,
                ),
            ],
          );
        }
        break;

      case BarcodeType.geo:
        final String lat = _parsedUriParams['lat'] ?? 'N/A';
        final String lon = _parsedUriParams['lon'] ?? 'N/A';
        final String? label = _parsedUriParams['q'];
        final String? alt = _parsedUriParams['alt'];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoRow(
              context,
              Icons.pin_drop_outlined,
              l10n.latitudeLabel,
              lat,
            ),
            _buildInfoRow(
              context,
              Icons.pin_drop_outlined,
              l10n.longitudeLabel,
              lon,
            ),
            if (alt != null)
              _buildInfoRow(
                context,
                Icons.layers_outlined,
                l10n.altitudeLabel,
                alt,
              ),
            if (label != null)
              _buildInfoRow(
                context,
                Icons.label_outline,
                l10n.labelLabel,
                label,
              ),
          ],
        );

      case BarcodeType.phone:
        if (_launchableUri != null) {
          final String number =
              _launchableUri!.path.isNotEmpty ? _launchableUri!.path : 'N/A';
          return SelectableText(
            number,
            style: textStyle?.copyWith(fontSize: 18),
            textAlign: TextAlign.center,
          );
        }
        break;

      case BarcodeType.url:
      case BarcodeType.text:
      case BarcodeType.isbn:
      case BarcodeType.product:
        return SelectableText(
          widget.code,
          style: textStyle?.copyWith(fontSize: 18),
          textAlign: TextAlign.center,
        );

      case BarcodeType.contactInfo:
        return _buildVCardContent(context);
      case BarcodeType.calendarEvent:
        return _buildRawContentWithLabel(context, l10n.calendarEventLabel);
      case BarcodeType.driverLicense:
        return _buildRawContentWithLabel(context, l10n.driverLicenseLabel);
      case BarcodeType.unknown:
        return _buildRawContentWithLabel(context, l10n.rawDataLabel);
    }

    return _buildRawContentWithLabel(context, l10n.rawDataLabel);
  }

  Widget _buildInfoRow(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    final theme = Theme.of(context);
    final textStyle = theme.textTheme.bodyLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final labelStyle = textStyle?.copyWith(fontWeight: FontWeight.bold);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: labelStyle?.color?.withAlpha(140), size: 20),
          const SizedBox(width: 8),
          Text(label, style: labelStyle),
          const SizedBox(width: 8),
          Flexible(child: SelectableText(value, style: textStyle)),
        ],
      ),
    );
  }

  Widget _buildRawContentWithLabel(BuildContext context, String label) {
    final theme = Theme.of(context);
    final textStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant.withAlpha(140),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: labelStyle),
        const SizedBox(height: 4),
        SelectableText(widget.code, style: textStyle),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;

    IconData topIcon = Icons.check_circle;
    Color topIconColor = Colors.green;
    String titleText = l10n.scanSuccessful;
    List<Widget> actionButtons = [];

    actionButtons.add(
      ElevatedButton.icon(
        icon: const Icon(Icons.copy),
        label: Text(l10n.copyRawValue),
        onPressed: () => _copyToClipboard(widget.code, l10n.rawValueCopied),
      ),
    );

    switch (widget.type) {
      case BarcodeType.url:
        if (_launchableUri != null) {
          topIcon = Icons.link;
          topIconColor = colorScheme.primary;
          titleText = l10n.linkFound;
          actionButtons.add(const SizedBox(height: 15));
          actionButtons.add(
            ElevatedButton.icon(
              icon: const Icon(Icons.open_in_browser),
              label: Text(l10n.openLink),
              onPressed: () => _launchUriAction(_launchableUri!),
              style: ElevatedButton.styleFrom(
                backgroundColor: colorScheme.secondary,
                foregroundColor: colorScheme.onSecondary,
              ),
            ),
          );
        }
        break;

      case BarcodeType.phone:
        if (_launchableUri != null) {
          topIcon = Icons.phone;
          topIconColor = colorScheme.primary;
          titleText = l10n.phoneNumberFound;
          actionButtons.add(const SizedBox(height: 15));
          actionButtons.add(
            ElevatedButton.icon(
              icon: const Icon(Icons.phone_in_talk),
              label: Text(l10n.dialNumber),
              onPressed: () => _launchUriAction(_launchableUri!),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green[700],
                foregroundColor: Colors.white,
              ),
            ),
          );
        }
        break;

      case BarcodeType.email:
        if (_launchableUri != null) {
          topIcon = Icons.email;
          topIconColor = colorScheme.primary;
          titleText = l10n.emailAddressFound;
          actionButtons.add(const SizedBox(height: 15));
          actionButtons.add(
            ElevatedButton.icon(
              icon: const Icon(Icons.email_outlined),
              label: Text(l10n.sendEmail),
              onPressed: () => _launchUriAction(_launchableUri!),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red[600],
                foregroundColor: Colors.white,
              ),
            ),
          );

          final recipient =
              _parsedUriParams['to'] ?? _launchableUri?.path ?? '';
          if (recipient.isNotEmpty) {
            actionButtons.add(const SizedBox(height: 10));
            actionButtons.add(
              ElevatedButton.icon(
                icon: const Icon(Icons.copy),
                label: Text(l10n.copyEmailAddress),
                onPressed:
                    () => _copyToClipboard(recipient, l10n.emailAddressCopied),
              ),
            );
          }
        }
        break;

      case BarcodeType.sms:
        if (_launchableUri != null) {
          topIcon = Icons.sms;
          topIconColor = colorScheme.primary;
          titleText = l10n.smsDetailsFound;
          actionButtons.add(const SizedBox(height: 15));
          actionButtons.add(
            ElevatedButton.icon(
              icon: const Icon(Icons.sms_outlined),
              label: Text(l10n.sendSms),
              onPressed: () => _launchUriAction(_launchableUri!),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurple[600],
                foregroundColor: Colors.white,
              ),
            ),
          );
        }
        break;

      case BarcodeType.wifi:
        if (_wifiCredentials != null) {
          topIcon = Icons.wifi;
          topIconColor = colorScheme.primary;
          titleText = l10n.wifiNetworkFound;
          actionButtons.add(const SizedBox(height: 15));
          actionButtons.add(
            ElevatedButton.icon(
              icon: const Icon(Icons.wifi_password),
              label: Text(l10n.copyWifiInfo),
              onPressed: _copyWifiCredentials,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue[700],
                foregroundColor: Colors.white,
              ),
            ),
          );
          actionButtons.add(
            Padding(
              padding: const EdgeInsets.only(top: 10.0),
              child: Text(
                l10n.wifiManualNote,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withAlpha(128),
                ),
              ),
            ),
          );
        }
        break;

      case BarcodeType.contactInfo:
        topIcon = Icons.contact_page_outlined;
        topIconColor = colorScheme.primary;
        titleText = l10n.contactInfoFound;
        actionButtons.add(
          ElevatedButton.icon(
            icon: const Icon(Icons.save_alt),
            label: Text(l10n.exportVCard),
            onPressed: _exportVCard,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange[700],
              foregroundColor: Colors.white,
            ),
          ),
        );
        break;

      case BarcodeType.geo:
        topIcon = Icons.location_on_outlined;
        topIconColor = colorScheme.primary;
        titleText = l10n.locationFound;
        if (_launchableUri != null) {
          actionButtons.add(
            ElevatedButton.icon(
              icon: const Icon(Icons.map_outlined),
              label: Text(l10n.openInMaps),
              onPressed: () => _launchUriAction(_launchableUri!),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.teal[600],
                foregroundColor: Colors.white,
              ),
            ),
          );
        }
        break;

      case BarcodeType.calendarEvent:
        topIcon = Icons.event;
        topIconColor = colorScheme.primary;
        titleText = l10n.calendarEventFound;
        break;
      case BarcodeType.text:
        topIcon = Icons.article;
        topIconColor = colorScheme.primary;
        titleText = l10n.textFound;
        break;
      case BarcodeType.isbn:
        topIcon = Icons.book;
        topIconColor = colorScheme.primary;
        titleText = l10n.isbnFound;
        break;
      case BarcodeType.product:
        topIcon = Icons.inventory_2;
        topIconColor = colorScheme.primary;
        titleText = l10n.productCodeFound;
        break;
      case BarcodeType.driverLicense:
        topIcon = Icons.badge;
        topIconColor = colorScheme.primary;
        titleText = l10n.driverLicenseFound;
        break;
      case BarcodeType.unknown:
        break;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.scanResultTitle),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colorScheme.onPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(topIcon, color: topIconColor, size: 100.0),
                const SizedBox(height: 20),
                Text(
                  titleText,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 25),

                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15.0,
                    vertical: 12.0,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8.0),
                    border: Border.all(color: colorScheme.outline),
                  ),
                  child: _buildFormattedContent(context),
                ),
                const SizedBox(height: 30),

                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: actionButtons,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
