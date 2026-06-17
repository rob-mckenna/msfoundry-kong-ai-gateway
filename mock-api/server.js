const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

// Request logging middleware
app.use((req, res, next) => {
  console.log(`${new Date().toISOString()} ${req.method} ${req.path}`);
  next();
});

// GET /api/weather?location=<city>
app.get('/api/weather', (req, res) => {
  const location = req.query.location;
  
  if (!location) {
    return res.status(400).json({
      error: 'Missing required parameter: location'
    });
  }

  // Mock weather data with some randomization
  const conditions = ['Sunny', 'Cloudy', 'Rainy', 'Partly Cloudy', 'Overcast'];
  const temps = [45, 50, 55, 60, 65, 70, 75, 80];
  const humidity = [60, 65, 70, 75, 80, 85];

  const weatherData = {
    location: location,
    temperature: temps[Math.floor(Math.random() * temps.length)],
    condition: conditions[Math.floor(Math.random() * conditions.length)],
    humidity: humidity[Math.floor(Math.random() * humidity.length)],
    timestamp: new Date().toISOString()
  };

  console.log(`Weather request for ${location}: ${JSON.stringify(weatherData)}`);
  res.json(weatherData);
});

// POST /api/calculate
app.post('/api/calculate', (req, res) => {
  const { operation, a, b } = req.body;

  // Input validation
  if (!operation || typeof a !== 'number' || typeof b !== 'number') {
    return res.status(400).json({
      error: 'Invalid input. Required: operation (string), a (number), b (number)'
    });
  }

  const validOps = ['add', 'subtract', 'multiply'];
  if (!validOps.includes(operation)) {
    return res.status(400).json({
      error: `Invalid operation. Must be one of: ${validOps.join(', ')}`
    });
  }

  let result;
  switch (operation) {
    case 'add':
      result = a + b;
      break;
    case 'subtract':
      result = a - b;
      break;
    case 'multiply':
      result = a * b;
      break;
  }

  const response = {
    operation,
    a,
    b,
    result
  };

  console.log(`Calculate: ${JSON.stringify(response)}`);
  res.json(response);
});

// GET /api/status
app.get('/api/status', (req, res) => {
  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    uptime: process.uptime()
  });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({
    error: 'Not found',
    path: req.path
  });
});

// Error handler
app.use((err, req, res, next) => {
  console.error('Error:', err);
  res.status(500).json({
    error: 'Internal server error',
    message: err.message
  });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Mock API server listening on port ${PORT}`);
  console.log(`Endpoints:`);
  console.log(`  GET  /api/weather?location=<city>`);
  console.log(`  POST /api/calculate (body: {operation, a, b})`);
  console.log(`  GET  /api/status`);
});
